import SwiftUI

struct TranscriptView: View {
    let utterances: [Utterance]
    var emptyStateMessage: String? = nil
    let volatileYouText: String
    let volatileThemText: String
    var showSearch: Bool = false
    /// Live speaker names (storageKey → name) for display.
    var speakerNames: [String: String]? = nil
    /// Attendee names offered as one-click naming suggestions.
    var nameSuggestions: [String] = []
    /// When set, lettered speakers can be named from the bubble context menu.
    var onRenameSpeaker: ((Speaker, String) -> Void)? = nil
    /// When set, You-labeled mic lines get a "Not me" correction action.
    var onNotMe: ((Utterance) -> Void)? = nil

    @State private var searchText = ""
    @State private var autoScrollEnabled = true
    @State private var volatileScrollTask: Task<Void, Never>?
    @State private var renamingSpeaker: Speaker? = nil
    @State private var renameText = ""

    private var filteredUtterances: [Utterance] {
        guard !searchText.isEmpty else { return utterances }
        return utterances.filter {
            $0.displayText.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var isSearching: Bool {
        showSearch && !searchText.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if showSearch {
                searchBar
                Divider()
            }
            transcriptScrollView
        }
        .alert(
            "Name \(renamingSpeaker?.displayLabel ?? "speaker")",
            isPresented: Binding(
                get: { renamingSpeaker != nil },
                set: { if !$0 { renamingSpeaker = nil } }
            )
        ) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let speaker = renamingSpeaker {
                    onRenameSpeaker?(speaker, renameText)
                }
                renamingSpeaker = nil
            }
            Button("Cancel", role: .cancel) { renamingSpeaker = nil }
        } message: {
            Text("The name applies to every line from this speaker, feeds the meeting notes, and survives the post-meeting re-transcription.")
        }
    }

    /// Context-menu corrections available on live bubbles.
    @ViewBuilder
    private func liveCorrectionMenu(for utterance: Utterance) -> some View {
        if let onRenameSpeaker, utterance.speaker.isRenameable {
            let label = utterance.speaker.displayName(speakerNames: speakerNames)
            let usedNames = Set(speakerNames?.values.map { $0 } ?? [])
            ForEach(nameSuggestions.filter { !usedNames.contains($0) }, id: \.self) { name in
                Button("\(label) is \(name)") {
                    onRenameSpeaker(utterance.speaker, name)
                }
            }
            Button("Name \(label)…") {
                renameText = speakerNames?[utterance.speaker.storageKey] ?? ""
                renamingSpeaker = utterance.speaker
            }
        }
        if let onNotMe, utterance.speaker == .you, utterance.source != .system {
            Divider()
            Button("Not me") { onNotMe(utterance) }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            TextField("Search transcript…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }

            Divider()
                .frame(height: 14)

            Button {
                autoScrollEnabled.toggle()
            } label: {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 11))
                    .foregroundStyle(autoScrollEnabled ? Color.secondary : Color.red)
            }
            .buttonStyle(.plain)
            .help(autoScrollEnabled ? "Pause auto-scroll" : "Resume auto-scroll")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }

    private var transcriptScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                let visible = filteredUtterances
                if visible.isEmpty && isSearching {
                    Text("No matches")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else if visible.isEmpty,
                          !isSearching,
                          volatileYouText.isEmpty,
                          volatileThemText.isEmpty,
                          let emptyStateMessage {
                    VStack(spacing: 8) {
                        Image(systemName: "clock.badge.exclamationmark")
                            .font(.system(size: 18))
                            .foregroundStyle(.tertiary)
                        Text(emptyStateMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 320)
                    }
                    .frame(maxWidth: .infinity, minHeight: 110)
                    .padding(16)
                } else {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(0..<visible.count, id: \.self) { index in
                            let utterance = visible[index]
                            UtteranceBubble(
                                utterance: utterance,
                                showTimestamp: shouldShowTimestamp(at: index, in: visible),
                                displayName: speakerNames?[utterance.speaker.storageKey]
                            )
                            .id(utterance.id)
                            .transition(.opacity)
                            .contextMenu { liveCorrectionMenu(for: utterance) }
                        }

                        if !isSearching {
                            if !volatileYouText.isEmpty {
                                VolatileIndicator(text: volatileYouText, speaker: .you)
                                    .id("volatile-you")
                            }

                            if !volatileThemText.isEmpty {
                                VolatileIndicator(text: volatileThemText, speaker: .them)
                                    .id("volatile-them")
                            }
                        }
                    }
                    .padding(16)
                    // Fade newly confirmed bubbles in rather than popping them;
                    // confirmed text itself is never rewritten (see CHI 2023
                    // caption-stability findings).
                    .animation(.easeOut(duration: 0.2), value: visible.count)
                }
            }
            .onChange(of: utterances.count) {
                guard !isSearching, autoScrollEnabled else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    if let last = utterances.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: volatileYouText) {
                scheduleVolatileScroll(proxy: proxy, id: "volatile-you")
            }
            .onChange(of: volatileThemText) {
                scheduleVolatileScroll(proxy: proxy, id: "volatile-them")
            }
            .onChange(of: searchText) {
                if searchText.isEmpty, autoScrollEnabled, let last = utterances.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !autoScrollEnabled {
                    Button {
                        autoScrollEnabled = true
                        if let last = utterances.last {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.white, Color.accentTeal)
                            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                    }
                    .buttonStyle(.plain)
                    .help("Resume auto-scroll")
                    .padding(12)
                    .transition(.opacity.combined(with: .scale))
                }
            }
        }
    }

    /// Coalesces rapid volatile-text updates (several can arrive within one
    /// frame from the live recognizer) into a single scroll, avoiding
    /// SwiftUI's multiple-updates-per-frame fault.
    private func scheduleVolatileScroll(proxy: ScrollViewProxy, id: String) {
        guard !isSearching, autoScrollEnabled else { return }
        volatileScrollTask?.cancel()
        volatileScrollTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            proxy.scrollTo(id, anchor: .bottom)
        }
    }

    private func shouldShowTimestamp(at index: Int, in visible: [Utterance]) -> Bool {
        guard index > 0 else { return true }
        let current = Calendar.current.dateComponents([.hour, .minute], from: visible[index].timestamp)
        let previous = Calendar.current.dateComponents([.hour, .minute], from: visible[index - 1].timestamp)
        return current.hour != previous.hour || current.minute != previous.minute
    }
}

// MARK: - Timestamp Formatter

private let timestampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f
}()

private struct UtteranceBubble: View {
    let utterance: Utterance
    var showTimestamp: Bool = true
    /// Custom name assigned during the live session, overriding the label.
    var displayName: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if showTimestamp {
                Text(timestampFormatter.string(from: utterance.timestamp))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 34, alignment: .trailing)
            } else {
                Spacer()
                    .frame(width: 34)
            }

            Text(displayName ?? utterance.speaker.displayLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(utterance.speaker.color)
                .frame(minWidth: 36, alignment: .trailing)

            Text(utterance.displayText)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }
}

/// Volatile (in-progress) hypothesis text, rendered inline where its final
/// bubble will land: dimmed and italic so it reads as provisional, with
/// interpolated content updates instead of flicker as the hypothesis is
/// revised, and a pulsing dot while the channel is being recognized.
private struct VolatileIndicator: View {
    let text: String
    let speaker: Speaker

    @State private var pulsing = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Spacer()
                .frame(width: 34)

            Text(speaker.displayLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(speaker.color.opacity(0.7))
                .frame(minWidth: 36, alignment: .trailing)

            (Text(text).italic() + Text(" ●").font(.system(size: 8)).foregroundStyle(speaker.color.opacity(pulsing ? 0.9 : 0.25)))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .contentTransition(.interpolate)
                .animation(.easeOut(duration: 0.18), value: text)
        }
        .opacity(0.65)
        .transition(.opacity)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
    }
}

// MARK: - Colors

extension Color {
    static let youColor = Color(red: 0.35, green: 0.55, blue: 0.75)    // muted blue
    static let themColor = Color(red: 0.82, green: 0.6, blue: 0.3)     // warm amber
    static let accentTeal = Color(red: 0.15, green: 0.55, blue: 0.55)  // deep teal
}
