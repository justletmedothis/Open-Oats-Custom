import Foundation
import Observation

@Observable
@MainActor
final class SidecastEngine {
    @ObservationIgnored nonisolated(unsafe) private var _messages: [SidecastMessage] = []
    private(set) var messages: [SidecastMessage] {
        get { access(keyPath: \.messages); return _messages }
        set { withMutation(keyPath: \.messages) { _messages = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _isGenerating = false
    private(set) var isGenerating: Bool {
        get { access(keyPath: \.isGenerating); return _isGenerating }
        set { withMutation(keyPath: \.isGenerating) { _isGenerating = newValue } }
    }

    var suggestions: [Suggestion] {
        messages
            .sorted { $0.timestamp > $1.timestamp }
            .map { Suggestion(text: "\($0.personaName): \($0.text)") }
    }

    private let client = OpenRouterClient()
    private let transcriptStore: TranscriptStore
    private let knowledgeBase: KnowledgeBase
    private let settings: AppSettings

    @ObservationIgnored nonisolated(unsafe) private var _lastErrorMessage: String?
    private(set) var lastErrorMessage: String? {
        get { access(keyPath: \.lastErrorMessage); return _lastErrorMessage }
        set { withMutation(keyPath: \.lastErrorMessage) { _lastErrorMessage = newValue } }
    }

    private var generationTask: Task<Void, Never>?
    private var activeGenerationID: UUID?
    private var lastProcessedUtteranceID: UUID?
    private var lastGenerationStartedAt: Date = .distantPast
    private var recentBubbleTexts: [String] = []
    private var lastSpokenAtByPersona: [UUID: Date] = [:]
    /// Latest utterance waiting for a generation slot. New utterances replace it
    /// (coalescing) instead of cancelling an in-flight generation — cancelling
    /// meant a slow model never got to answer at all.
    private var pendingUtterance: Utterance?
    private var cooldownRetryTask: Task<Void, Never>?

    private static let liveGenerationTimeout: TimeInterval = 20

    init(transcriptStore: TranscriptStore, knowledgeBase: KnowledgeBase, settings: AppSettings) {
        self.transcriptStore = transcriptStore
        self.knowledgeBase = knowledgeBase
        self.settings = settings
    }

    func onUtterance(_ utterance: Utterance) {
        guard utterance.id != lastProcessedUtteranceID else { return }
        lastProcessedUtteranceID = utterance.id

        guard settings.sidebarMode == .sidecast else { return }
        guard !settings.enabledSidecastPersonas.isEmpty else { return }
        guard canCallLLM else { return }

        pendingUtterance = utterance
        maybeStartGeneration()
    }

    /// Starts a generation for the pending utterance if no generation is in
    /// flight and the cooldown has elapsed. Called on new utterances, when a
    /// generation finishes, and from the cooldown retry timer.
    private func maybeStartGeneration() {
        guard activeGenerationID == nil else { return }
        guard pendingUtterance != nil else { return }
        guard settings.sidebarMode == .sidecast, !settings.enabledSidecastPersonas.isEmpty else {
            pendingUtterance = nil
            return
        }

        let cooldown = settings.sidecastIntensity.generationCooldownSeconds
        let elapsed = Date.now.timeIntervalSince(lastGenerationStartedAt)
        guard elapsed >= cooldown else {
            scheduleCooldownRetry(after: cooldown - elapsed)
            return
        }

        guard let utterance = pendingUtterance else { return }
        pendingUtterance = nil
        startGeneration(for: utterance)
    }

    private func scheduleCooldownRetry(after delay: TimeInterval) {
        guard cooldownRetryTask == nil else { return }
        cooldownRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.1, delay)))
            guard let self, !Task.isCancelled else { return }
            self.cooldownRetryTask = nil
            self.maybeStartGeneration()
        }
    }

    private func startGeneration(for utterance: Utterance) {
        lastGenerationStartedAt = .now
        let generationID = UUID()
        activeGenerationID = generationID
        isGenerating = true

        let personas = settings.enabledSidecastPersonas
        let recentExchange = transcriptStore.recentExchange
        let recentUtterances = transcriptStore.recentUtterances
        let conversationState = transcriptStore.conversationState

        generationTask = Task { [weak self] in
            guard let self else { return }

            let evidence = await self.loadEvidence(for: utterance.text)
            let prompt = self.buildPrompt(
                utterance: utterance,
                recentExchange: recentExchange,
                recentUtterances: recentUtterances,
                state: conversationState,
                personas: personas,
                evidence: evidence
            )

            var attempt = 0
            while true {
                do {
                    let acceptedCount = try await self.runStreamedGeneration(
                        prompt: prompt,
                        personas: personas,
                        evidence: evidence
                    )
                    self.lastErrorMessage = nil
                    Log.sidecast.info("Generation finished with \(acceptedCount) message(s)")
                    break
                } catch is CancellationError {
                    break
                } catch {
                    Log.sidecast.error("Generation failed (attempt \(attempt + 1)): \(error, privacy: .public)")
                    if attempt == 0, Self.isTransient(error), !Task.isCancelled {
                        attempt += 1
                        try? await Task.sleep(for: .seconds(1))
                        continue
                    }
                    self.lastErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    break
                }
            }

            self.finishGeneration(generationID)
            self.maybeStartGeneration()
        }
    }

    /// Streams the model response, applying persona messages incrementally as
    /// each NDJSON line completes so bubbles render without waiting for the
    /// whole response. Falls back to whole-response JSON parsing for models
    /// (or custom system prompts) that still return the legacy wrapper object.
    /// Returns the number of accepted messages.
    private func runStreamedGeneration(
        prompt: [OpenRouterClient.Message],
        personas: [SidecastPersona],
        evidence: [KBContextPack]
    ) async throws -> Int {
        let stream = await client.streamCompletion(
            apiKey: llmApiKey,
            model: settings.activeRealtimeModel,
            messages: prompt,
            maxTokens: settings.sidecastMaxTokens,
            temperature: settings.sidecastTemperature,
            baseURL: llmBaseURL,
            webSearch: shouldUseWebSearch(for: personas),
            transport: settings.activeLLMTransport,
            requestTimeout: Self.liveGenerationTimeout
        )

        var fullResponse = ""
        var lineBuffer = ""
        var acceptedCount = 0
        var parsedAnyLine = false

        func processLine(_ line: String) {
            var remainder = Substring(line)
            while let object = Self.firstBalancedJSONObject(in: remainder) {
                if let candidate = Self.decodeCandidate(object.text) {
                    parsedAnyLine = true
                    if accept(candidate, personas: personas, evidence: evidence, acceptedCount: acceptedCount) {
                        acceptedCount += 1
                    }
                }
                remainder = remainder[object.range.upperBound...]
            }
        }

        for try await chunk in stream {
            fullResponse += chunk
            lineBuffer += chunk
            while let newline = lineBuffer.firstIndex(of: "\n") {
                let line = String(lineBuffer[..<newline])
                lineBuffer = String(lineBuffer[lineBuffer.index(after: newline)...])
                processLine(line)
            }
        }
        processLine(lineBuffer)

        if !parsedAnyLine {
            let trimmed = fullResponse.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return acceptedCount }
            let decoded = try decodeResponse(fullResponse)
            let ranked = decoded.messages
                .sorted { ($0.priority ?? 0) > ($1.priority ?? 0) }
            for candidate in ranked {
                if accept(candidate, personas: personas, evidence: evidence, acceptedCount: acceptedCount) {
                    acceptedCount += 1
                }
            }
        }

        return acceptedCount
    }

    private static func isTransient(_ error: Error) -> Bool {
        if error is URLError { return true }
        if case OpenRouterClient.OpenRouterError.httpError(let code, _) = error {
            return code == 429 || (500...599).contains(code)
        }
        return false
    }

    func message(for personaID: UUID) -> SidecastMessage? {
        messages.first(where: { $0.personaID == personaID })
    }

    func clear() {
        generationTask?.cancel()
        generationTask = nil
        cooldownRetryTask?.cancel()
        cooldownRetryTask = nil
        pendingUtterance = nil
        messages.removeAll()
        isGenerating = false
        lastErrorMessage = nil
        activeGenerationID = nil
        lastProcessedUtteranceID = nil
        lastGenerationStartedAt = .distantPast
        recentBubbleTexts.removeAll()
        lastSpokenAtByPersona.removeAll()
    }

    private func finishGeneration(_ generationID: UUID) {
        guard activeGenerationID == generationID else { return }
        activeGenerationID = nil
        isGenerating = false
    }

    /// Filters one candidate and, if it passes, renders its bubble immediately.
    /// Returns whether the candidate was accepted. `acceptedCount` is how many
    /// candidates this turn already accepted (caps at maxMessagesPerTurn).
    private func accept(
        _ candidate: SidecastCandidate,
        personas: [SidecastPersona],
        evidence: [KBContextPack],
        acceptedCount: Int
    ) -> Bool {
        guard candidate.speak else { return false }
        guard acceptedCount < settings.sidecastIntensity.maxMessagesPerTurn else { return false }

        let persona: SidecastPersona? = personas.first { p in
            if let id = candidate.personaID { return p.id == id }
            return false
        } ?? candidate.personaName.flatMap { name in
            personas.first { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        }
        guard let persona else { return false }

        let now = Date.now
        if !settings.sidecastIntensity.skipPersonaCooldowns,
           let lastSpoken = lastSpokenAtByPersona[persona.id],
           now.timeIntervalSince(lastSpoken) < persona.cadence.cooldownSeconds {
            return false
        }

        let cleanedText = sanitize(candidate.text, limit: persona.verbosity.characterLimit)
        guard !cleanedText.isEmpty else { return false }

        if recentBubbleTexts.contains(where: { TextSimilarity.jaccard($0, cleanedText) > 0.62 }) {
            return false
        }

        let value = max(0, min(1, candidate.value ?? 0.5))
        if value < settings.sidecastMinValueThreshold { return false }

        let evidenceRequired = persona.evidencePolicy == .required
        if evidenceRequired && !persona.webSearchEnabled && evidence.isEmpty {
            return false
        }

        let confidence = max(0, min(1, candidate.confidence ?? 0.55))
        if evidenceRequired && !persona.webSearchEnabled && confidence < 0.35 {
            return false
        }

        let message = SidecastMessage(
            personaID: persona.id,
            personaName: persona.name,
            text: cleanedText,
            timestamp: now,
            confidence: confidence,
            priority: candidate.priority ?? 0.5,
            value: value,
            sourceBreadcrumb: evidence.first?.displayBreadcrumb ?? ""
        )

        lastSpokenAtByPersona[persona.id] = now
        recentBubbleTexts.append(cleanedText)
        if recentBubbleTexts.count > 12 {
            recentBubbleTexts.removeFirst(recentBubbleTexts.count - 12)
        }

        var updated = Dictionary(uniqueKeysWithValues: messages.map { ($0.personaID, $0) })
        updated[message.personaID] = message
        messages = updated.values.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
            return lhs.personaName < rhs.personaName
        }
        return true
    }

    private static let sanitizePatterns: [(NSRegularExpression, String)] = {
        let patterns: [(String, String)] = [
            (#"\[([^\]]*)\]\([^)]+\)"#, "$1"),                             // [text](url) → text
            (#"https?://\S+"#, ""),                                         // bare URLs
            (#"\b\w+\.(com|org|net|io|ai|app|dev|co|edu|gov)\b"#, ""),     // bare domains
            (#"\([^)]*\b(source|via|per|from|according)\b[^)]*\)"#, ""),   // (source: …) parentheticals
            (#"\[\s*\]"#, ""),                                              // leftover empty []
        ]
        return patterns.compactMap { (pattern, template) in
            (try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)).map { ($0, template) }
        }
    }()

    private func sanitize(_ text: String, limit: Int) -> String {
        var result = text
        for (regex, template) in Self.sanitizePatterns {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        let collapsed = result
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
        guard !collapsed.isEmpty else { return "" }
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadEvidence(for text: String) async -> [KBContextPack] {
        guard settings.kbFolderURL != nil else { return [] }
        return await knowledgeBase.searchContextPacks(queries: [text], topK: 3)
    }

    private func buildPrompt(
        utterance: Utterance,
        recentExchange: [Utterance],
        recentUtterances: [Utterance],
        state: ConversationState,
        personas: [SidecastPersona],
        evidence: [KBContextPack]
    ) -> [OpenRouterClient.Message] {
        let personaText = personas.map { persona in
            """
            - id: \(persona.id.uuidString)
              name: \(persona.name)
              subtitle: \(persona.subtitle)
              prompt: \(persona.prompt)
              verbosity: \(persona.verbosity.displayName) (max \(persona.verbosity.characterLimit) chars)
              cadence: \(persona.cadence.displayName)
              evidence: \(persona.evidencePolicy.displayName)
            """
        }.joined(separator: "\n")

        let transcriptText = recentExchange
            .map { "\($0.speaker.displayLabel): \($0.text)" }
            .joined(separator: "\n")

        let widerContext = recentUtterances
            .map { "\($0.speaker.displayLabel): \($0.text)" }
            .joined(separator: "\n")

        let evidenceText: String
        if evidence.isEmpty {
            evidenceText = "No KB evidence retrieved for this turn."
        } else {
            evidenceText = evidence.enumerated().map { index, pack in
                """
                [\(index + 1)] \(pack.displayBreadcrumb) (score \(String(format: "%.2f", pack.score)))
                \(pack.matchedText)
                """
            }.joined(separator: "\n\n")
        }

        let stateSummary = state.shortSummary.isEmpty ? "No structured state yet." : state.shortSummary
        let openQuestions = state.openQuestions.isEmpty ? "None" : state.openQuestions.joined(separator: "; ")

        let systemTemplate = settings.sidecastSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let system: String
        if systemTemplate.isEmpty {
            system = """
            You are Sidecast, a live multi-persona producer for a host-assist sidebar.
            Decide which personas should speak right now in response to the latest utterance.

            Quality bar:
            - Only speak when you have genuine insight — a non-obvious fact, a sharp reframe, a useful correction, or a punchy callback.
            - Silence is better than filler. If nothing clears the bar, output exactly one line: {"speak":false}
            - Every bubble should make the host think "glad I saw that." If it wouldn't, don't send it.

            Rules:
            - Output NDJSON: one complete JSON object per line, nothing else — no wrapper object, no code fences, no commentary before or after.
            - Use at most \(settings.sidecastIntensity.maxMessagesPerTurn) persona messages.
            - Never include URLs, links, citations, or source references in the text. The text is the insight itself, nothing else.
            - No markdown, no emoji, no stage directions, no quotes around the text.
            - Keep text extremely dense — every word must earn its place.
            - Fact-heavy personas must lead with specific numbers, percentages, dates, or named sources. Never say "X is higher" — say "X is 42% higher." Avoid vague qualifiers like "significantly", "increasingly", "many" — replace them with the actual number. If no precise data is available, stay silent rather than generalizing.
            - Humor and chaos personas can be sharp, but never hateful or unusably toxic.
            - Set priority (0.0–1.0) honestly: 0.9+ means "the host needs to see this right now." Most messages should be 0.4–0.7.
            - Set confidence (0.0–1.0) based on how sure you are the claim is correct. Below 0.5 means you're guessing.
            - Set value (0.0–1.0): how much this message would genuinely help the host. Be brutally honest.
              0.0–0.3: generic, obvious, or hollow — anyone could say this. Do not send.
              0.4–0.5: mildly interesting but not actionable.
              0.6–0.7: solid insight the host probably didn't know or hadn't considered.
              0.8–1.0: genuinely surprising, corrects a misconception, or provides a killer reframe.

            Output format — one line per speaking persona, emitted in order of priority (highest first):
            {"persona_id":"UUID","speak":true,"text":"string","priority":0.0,"confidence":0.0,"value":0.0}
            """
        } else {
            system = systemTemplate
                .replacingOccurrences(of: "{{maxMessagesPerTurn}}", with: "\(settings.sidecastIntensity.maxMessagesPerTurn)")
        }

        let user = """
        Latest utterance:
        \(utterance.speaker.displayLabel): \(utterance.text)

        Recent exchange:
        \(transcriptText)

        Wider context:
        \(widerContext)

        Conversation summary:
        \(stateSummary)

        Open questions:
        \(openQuestions)

        Personas:
        \(personaText)

        Evidence:
        \(evidenceText)
        """

        return [
            .init(role: "system", content: system),
            .init(role: "user", content: user),
        ]
    }

    private func decodeResponse(_ response: String) throws -> SidecastResponse {
        let json = extractJSON(from: response)
        guard let data = json.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid UTF-8 response"))
        }
        return try JSONDecoder().decode(SidecastResponse.self, from: data)
    }

    /// Best-effort JSON recovery from model output: drops reasoning blocks and
    /// code fences, then extracts the first balanced top-level object. Free and
    /// reasoning models routinely wrap JSON in <think> blocks or prose.
    private func extractJSON(from text: String) -> String {
        var s = text
        s = s.replacingOccurrences(
            of: #"(?is)<think>.*?</think>"#,
            with: "",
            options: .regularExpression
        )
        s = s.replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let object = Self.firstBalancedJSONObject(in: Substring(s)) {
            return object.text
        }
        return s
    }

    /// Finds the first balanced `{…}` object (string- and escape-aware).
    /// Returns the object text and its range so callers can scan for more.
    static func firstBalancedJSONObject(in text: Substring) -> (text: String, range: Range<Substring.Index>)? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let ch = text[index]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else {
                switch ch {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        let end = text.index(after: index)
                        return (String(text[start..<end]), start..<end)
                    }
                default: break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Decodes a single NDJSON candidate line. Non-candidate objects (e.g. the
    /// legacy `{"messages":[…]}` wrapper, malformed lines) return nil so the
    /// caller can fall back to whole-response parsing.
    static func decodeCandidate(_ json: String) -> SidecastCandidate? {
        guard let data = json.data(using: .utf8) else { return nil }
        guard let candidate = try? JSONDecoder().decode(SidecastCandidate.self, from: data) else { return nil }
        // Accept objects that identify a persona, or an explicit {"speak":false}
        // "nothing to say" line. Reject shapeless objects (legacy wrapper).
        guard candidate.personaID != nil || candidate.personaName != nil || candidate.hadSpeakKey else { return nil }
        return candidate
    }

    private var canCallLLM: Bool {
        switch settings.llmProvider {
        case .openRouter:
            return !settings.openRouterApiKey.isEmpty
        case .requesty:
            return !settings.requestyApiKey.isEmpty && llmBaseURL != nil
        case .openAI:
            return !settings.openAIApiKey.isEmpty && llmBaseURL != nil
        case .anthropic:
            return !settings.anthropicApiKey.isEmpty && llmBaseURL != nil
        case .ollama, .lmStudio, .mlx, .openAICompatible:
            return llmBaseURL != nil
        }
    }

    private var llmApiKey: String? {
        switch settings.llmProvider {
        case .openRouter: settings.openRouterApiKey
        case .requesty:
            settings.requestyApiKey.isEmpty ? nil : settings.requestyApiKey
        case .openAI:
            settings.openAIApiKey.isEmpty ? nil : settings.openAIApiKey
        case .anthropic:
            settings.anthropicApiKey.isEmpty ? nil : settings.anthropicApiKey
        case .ollama: nil
        case .lmStudio:
            settings.lmStudioApiKey.isEmpty ? nil : settings.lmStudioApiKey
        case .mlx: nil
        case .openAICompatible:
            settings.openAILLMApiKey.isEmpty ? nil : settings.openAILLMApiKey
        }
    }

    /// Web search is enabled when the provider is OpenRouter and any enabled persona has it on.
    private func shouldUseWebSearch(for personas: [SidecastPersona]) -> Bool {
        settings.llmProvider == .openRouter && personas.contains(where: { $0.webSearchEnabled })
    }

    private var llmBaseURL: URL? {
        switch settings.llmProvider {
        case .openRouter: nil
        case .requesty:
            OpenRouterClient.chatCompletionsURL(from: settings.requestyBaseURL)
        case .openAI:
            OpenRouterClient.chatCompletionsURL(from: settings.openAIBaseURL)
        case .anthropic:
            OpenRouterClient.anthropicMessagesURL(from: settings.anthropicBaseURL)
        case .ollama:
            OpenRouterClient.chatCompletionsURL(from: settings.ollamaBaseURL)
        case .lmStudio:
            OpenRouterClient.chatCompletionsURL(from: settings.lmStudioBaseURL)
        case .mlx:
            OpenRouterClient.chatCompletionsURL(from: settings.mlxBaseURL)
        case .openAICompatible:
            OpenRouterClient.chatCompletionsURL(from: settings.openAILLMBaseURL)
        }
    }
}

private struct SidecastResponse: Decodable {
    let messages: [SidecastCandidate]
}

/// One persona message from the model. Decoding is deliberately tolerant:
/// free/reasoning models botch UUIDs, omit fields, and mix formats, so every
/// field is recovered best-effort and persona resolution falls back to name.
struct SidecastCandidate: Decodable {
    let personaID: UUID?
    let personaName: String?
    let speak: Bool
    /// Whether the JSON contained an explicit "speak" key — distinguishes a
    /// deliberate {"speak":false} line from an unrelated JSON object.
    let hadSpeakKey: Bool
    let text: String
    let priority: Double?
    let confidence: Double?
    let value: Double?

    private enum CodingKeys: String, CodingKey {
        case personaID = "persona_id"
        case name
        case persona
        case speak
        case text
        case priority
        case confidence
        case value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let idString = ((try? container.decodeIfPresent(String.self, forKey: .personaID)) ?? nil)
        personaID = idString.flatMap(UUID.init(uuidString:))
        let primaryName = ((try? container.decodeIfPresent(String.self, forKey: .name)) ?? nil)
        let altName = ((try? container.decodeIfPresent(String.self, forKey: .persona)) ?? nil)
        // A non-UUID persona_id string (e.g. "the-checker") still identifies by name.
        let idAsName = (personaID == nil) ? idString : nil
        personaName = primaryName ?? altName ?? idAsName
        let speakValue = ((try? container.decodeIfPresent(Bool.self, forKey: .speak)) ?? nil)
        hadSpeakKey = speakValue != nil
        speak = speakValue ?? true
        text = ((try? container.decodeIfPresent(String.self, forKey: .text)) ?? nil) ?? ""
        priority = ((try? container.decodeIfPresent(Double.self, forKey: .priority)) ?? nil)
        confidence = ((try? container.decodeIfPresent(Double.self, forKey: .confidence)) ?? nil)
        value = ((try? container.decodeIfPresent(Double.self, forKey: .value)) ?? nil)
    }
}
