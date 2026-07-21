import Foundation
import Observation

/// A single turn in the live meeting chat.
struct LiveChatMessage: Identifiable, Equatable {
    enum Role: Equatable {
        case user
        case assistant
    }

    let id = UUID()
    let role: Role
    var text: String
}

private enum LiveChatFormatters {
    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

/// Prompt construction for the live meeting chat, kept off the engine so it
/// stays trivially testable.
enum LiveChatPrompt {
    static let transcriptCharacterLimit = 80_000

    /// Renders the transcript frozen at the moment the user hit send. Volatile
    /// (not yet finalized) hypothesis text is included so the snapshot covers
    /// words spoken seconds ago, but labeled so the model knows it may shift.
    static func formatSnapshot(
        utterances: [Utterance],
        speakerNames: [String: String]?,
        volatileYouText: String,
        volatileThemText: String,
        snapshotDate: Date
    ) -> String {
        var lines = utterances.map { utterance in
            let timestamp = LiveChatFormatters.timeFormatter.string(from: utterance.timestamp)
            return "[\(timestamp)] \(utterance.speaker.displayName(speakerNames: speakerNames)): \(utterance.displayText)"
        }
        let volatileYou = volatileYouText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !volatileYou.isEmpty {
            lines.append("[in progress] \(Speaker.you.displayName(speakerNames: speakerNames)): \(volatileYou)")
        }
        let volatileThem = volatileThemText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !volatileThem.isEmpty {
            lines.append("[in progress] \(Speaker.them.displayName(speakerNames: speakerNames)): \(volatileThem)")
        }

        let header = "Live transcript snapshot taken at \(LiveChatFormatters.timeFormatter.string(from: snapshotDate)):"
        guard !lines.isEmpty else {
            return header + "\n(No speech captured yet.)"
        }
        return header + "\n" + truncatedTranscript(lines.joined(separator: "\n"))
    }

    static func truncatedTranscript(_ fullText: String) -> String {
        guard fullText.count > transcriptCharacterLimit else { return fullText }

        let halfLimit = transcriptCharacterLimit / 2
        let prefix = fullText.prefix(halfLimit)
        let suffix = fullText.suffix(halfLimit)
        return "\(prefix)\n\n[Transcript truncated: middle omitted]\n\n\(suffix)"
    }

    static func buildMessages(
        question: String,
        transcriptSnapshot: String,
        history: [LiveChatMessage]
    ) -> [OpenRouterClient.Message] {
        var messages = [
            OpenRouterClient.Message(
                role: "system",
                content: """
                You answer questions during a live, in-progress meeting. The transcript below is a snapshot taken at the moment the user sent their latest message; nothing said after that instant is included. Use only the transcript and the chat history. If the transcript does not contain the answer, say that. Be concise, cite speaker labels and rough timestamps when useful, and do not invent details.
                """
            ),
            OpenRouterClient.Message(
                role: "user",
                content: """
                Transcript:
                \(transcriptSnapshot)
                """
            )
        ]

        let recentHistory = history.suffix(12)
        messages.append(contentsOf: recentHistory.map { message in
            OpenRouterClient.Message(
                role: message.role == .user ? "user" : "assistant",
                content: message.text
            )
        })
        messages.append(OpenRouterClient.Message(role: "user", content: question))

        return messages
    }
}

/// Answers user questions during a live recording. Each question is grounded
/// in a snapshot of the transcript taken at the moment it is sent, so the
/// answer reflects exactly what had been said up to that instant.
@Observable
@MainActor
final class LiveChatEngine {
    @ObservationIgnored nonisolated(unsafe) private var _messages: [LiveChatMessage] = []
    private(set) var messages: [LiveChatMessage] {
        get { access(keyPath: \.messages); return _messages }
        set { withMutation(keyPath: \.messages) { _messages = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _isResponding = false
    private(set) var isResponding: Bool {
        get { access(keyPath: \.isResponding); return _isResponding }
        set { withMutation(keyPath: \.isResponding) { _isResponding = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _error: String?
    private(set) var error: String? {
        get { access(keyPath: \.error); return _error }
        set { withMutation(keyPath: \.error) { _error = newValue } }
    }

    private let transcriptStore: TranscriptStore
    private let settings: AppSettings
    private let client = OpenRouterClient()
    private var currentTask: Task<Void, Never>?

    init(transcriptStore: TranscriptStore, settings: AppSettings) {
        self.transcriptStore = transcriptStore
        self.settings = settings
    }

    func send(_ question: String, speakerNames: [String: String]) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isResponding else { return }

        let snapshot = LiveChatPrompt.formatSnapshot(
            utterances: transcriptStore.utterances,
            speakerNames: speakerNames,
            volatileYouText: transcriptStore.volatileYouText,
            volatileThemText: transcriptStore.volatileThemText,
            snapshotDate: .now
        )

        let history = messages
        error = nil
        messages.append(LiveChatMessage(role: .user, text: trimmed))
        isResponding = true

        let promptMessages = LiveChatPrompt.buildMessages(
            question: trimmed,
            transcriptSnapshot: snapshot,
            history: history
        )
        let apiKey = settings.activeLLMApiKey
        let model = settings.activeNotesModel
        let baseURL = settings.activeLLMBaseURL
        let transport = settings.activeLLMTransport

        currentTask?.cancel()
        currentTask = Task { [weak self] in
            guard let self else { return }
            var replyID: UUID?
            do {
                let stream = await self.client.streamCompletion(
                    apiKey: apiKey,
                    model: model,
                    messages: promptMessages,
                    baseURL: baseURL,
                    transport: transport
                )
                for try await chunk in stream {
                    guard !Task.isCancelled else { break }
                    if let replyID, let index = self.messages.firstIndex(where: { $0.id == replyID }) {
                        self.messages[index].text += chunk
                    } else {
                        let reply = LiveChatMessage(role: .assistant, text: chunk)
                        replyID = reply.id
                        self.messages.append(reply)
                    }
                }
                if replyID == nil, !Task.isCancelled {
                    self.error = "The model returned an empty response."
                }
            } catch is CancellationError {
                // Cancelled sends keep whatever partial reply already arrived.
            } catch {
                if !Task.isCancelled {
                    self.error = error.localizedDescription
                }
            }
            self.isResponding = false
            self.currentTask = nil
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        isResponding = false
    }

    func clear() {
        cancel()
        messages = []
        error = nil
    }
}
