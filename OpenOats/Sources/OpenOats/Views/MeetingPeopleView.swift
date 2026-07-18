import SwiftUI

extension Speaker {
    /// Whether this is an in-person (microphone channel) voice — the user or
    /// a lettered local speaker — as opposed to a call participant. The
    /// in-room people count compares against these only.
    var isInRoomVoice: Bool {
        switch self {
        case .you, .local: true
        case .them, .remote: false
        }
    }
}

/// Compact "people" button for the control bar and the live transcript
/// header. Opens a popover that works on the fly, before and during a
/// meeting: cap how many in-person voices diarization should separate,
/// see who has been detected so far (renaming them inline), and see which
/// saved voices from the library are in the room.
struct MeetingPeopleButton: View {
    let state: LiveSessionState
    var controller: LiveSessionController?
    @Bindable var settings: AppSettings
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "person.2")
                    .font(.system(size: 11))
                if state.isRunning {
                    let speakers = MeetingPeopleView.orderedSpeakers(in: state.liveTranscript)
                    let expected = settings.expectedInRoomSpeakers
                    if expected > 0 {
                        // "Separated so far / expected" for in-room voices, so
                        // the stepper is visibly acknowledged mid-meeting.
                        let inRoom = speakers.filter(\.isInRoomVoice).count
                        Text("\(inRoom)/\(expected)")
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                    } else if !speakers.isEmpty {
                        Text("\(speakers.count)")
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                    }
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.05))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("People: expected speaker count, names, and saved voices")
        .accessibilityIdentifier("app.meetingPeople.button")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            MeetingPeopleView(state: state, controller: controller, settings: settings)
        }
    }
}

/// Popover content behind MeetingPeopleButton. Everything here is safe to
/// change mid-meeting: the speaker cap is read when the meeting is finalized
/// (the batch pass), and renames flow through the same live-rename path as
/// the transcript bubbles.
struct MeetingPeopleView: View {
    let state: LiveSessionState
    var controller: LiveSessionController?
    @Bindable var settings: AppSettings

    @State private var library: [SpeakerProfile] = []
    @State private var selfVoiceEnrolled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            expectedSpeakersSection

            if state.isRunning {
                Divider()
                detectedSpeakersSection
            }

            Divider()
            librarySection
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            library = SpeakerLibraryStore.load()
            selfVoiceEnrolled = VoiceprintStore.load() != nil
        }
    }

    private var nameSuggestions: [String] {
        // Exclude only names the USER assigned: a wrong auto-guess must stay
        // offerable so it can be corrected onto the right speaker (assigning
        // it overrides the guess everywhere).
        Self.nameSuggestions(
            invitees: state.matchedCalendarEvent?.participants.compactMap(\.displayName) ?? [],
            savedVoices: library.map(\.name),
            assignedNames: Array(state.liveSpeakerNames.values)
        )
    }

    /// Names offered in each row's dropdown: calendar invitees first, then
    /// saved voices, deduplicated case-insensitively and minus anyone
    /// already assigned to a speaker.
    static func nameSuggestions(
        invitees: [String], savedVoices: [String], assignedNames: [String]
    ) -> [String] {
        var seen = Set(assignedNames.map { $0.lowercased() })
        var names: [String] = []
        for name in invitees + savedVoices {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            names.append(trimmed)
        }
        return names
    }

    /// Distinct speakers in order of first appearance in the live transcript.
    static func orderedSpeakers(in utterances: [Utterance]) -> [Speaker] {
        var seen = Set<String>()
        var ordered: [Speaker] = []
        for utterance in utterances {
            let key = utterance.speaker.storageKey
            if seen.insert(key).inserted {
                ordered.append(utterance.speaker)
            }
        }
        return ordered
    }

    // MARK: - Sections

    @ViewBuilder
    private var expectedSpeakersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Stepper(value: $settings.expectedInRoomSpeakers, in: 0...12) {
                HStack {
                    Text("In-room people")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(settings.expectedInRoomSpeakers == 0 ? "Auto" : "\(settings.expectedInRoomSpeakers)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Text("Counting you. Caps how many in-person voices get separated. Change it any time before the meeting ends; it applies when the final transcript is built.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var detectedSpeakersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("In this meeting")
                .font(.system(size: 12, weight: .medium))

            let speakers = Self.orderedSpeakers(in: state.liveTranscript)
            if speakers.isEmpty {
                Text("No speech detected yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(speakers, id: \.storageKey) { speaker in
                    let isLettered: Bool = if case .local = speaker { true } else { false }
                    LiveSpeakerNameRow(
                        speaker: speaker,
                        userName: state.liveSpeakerNames[speaker.storageKey],
                        autoName: state.liveAutoSpeakerNames[speaker.storageKey],
                        suggestions: speaker == .you ? [] : nameSuggestions,
                        onAssignToMe: isLettered ? {
                            controller?.assignLiveSpeakerToMe(speaker)
                        } : nil,
                        onCommit: { name in
                            controller?.renameLiveSpeaker(speaker, to: name)
                        }
                    )
                }
                Text("Names you set here are remembered as that person's voice when the meeting is saved.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            let missing = Self.awaitedVoiceCount(
                expected: settings.expectedInRoomSpeakers, speakers: speakers
            )
            if missing > 0 {
                ForEach(0..<missing, id: \.self) { _ in
                    HStack(spacing: 6) {
                        Circle()
                            .strokeBorder(
                                Color.secondary.opacity(0.5),
                                style: StrokeStyle(lineWidth: 1, dash: [1.5])
                            )
                            .frame(width: 7, height: 7)
                        Text("Listening for another voice…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                Text("A person gets a row here once their voice is told apart. If someone's words are landing on the wrong speaker, right-click that line in the transcript and use \u{201C}Not me\u{201D} or name it.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// How many expected in-room people have no separated voice yet. Remote
    /// call voices don't count against the in-room expectation.
    static func awaitedVoiceCount(expected: Int, speakers: [Speaker]) -> Int {
        max(0, expected - speakers.filter(\.isInRoomVoice).count)
    }

    @ViewBuilder
    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Saved voices")
                .font(.system(size: 12, weight: .medium))

            HStack(spacing: 6) {
                Image(systemName: selfVoiceEnrolled ? "checkmark.seal.fill" : "person.crop.circle.badge.questionmark")
                    .font(.system(size: 10))
                    .foregroundStyle(selfVoiceEnrolled ? Color.accentColor : Color.secondary)
                Text("You")
                    .font(.system(size: 12))
                Text(selfVoiceEnrolled ? "voice enrolled" : "no voice profile yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if library.isEmpty {
                Text("No other saved voices yet. Name a speaker above (or rename one in a transcript with \u{201C}Remember this voice\u{201D}) and they will be recognized automatically in future meetings.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(library) { profile in
                    LibraryVoiceRow(
                        profile: profile,
                        isHere: state.isRunning && isInMeeting(profile.name),
                        onRename: { newName in
                            SpeakerLibraryStore.rename(id: profile.id, to: newName)
                            library = SpeakerLibraryStore.load()
                        },
                        onForget: {
                            SpeakerLibraryStore.delete(id: profile.id)
                            library = SpeakerLibraryStore.load()
                        }
                    )
                }
            }

            Text("Voices stay on this Mac. Also in Settings > Transcription > People.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private func isInMeeting(_ name: String) -> Bool {
        state.displaySpeakerNames.values.contains {
            $0.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }
}

/// One saved-voice row in the manageable library index: name with sample
/// count, a "here" badge when that voice is in the current meeting, and
/// rename / forget controls (same actions as Settings > People).
private struct LibraryVoiceRow: View {
    let profile: SpeakerProfile
    let isHere: Bool
    let onRename: (String) -> Void
    let onForget: () -> Void

    @State private var draft = ""
    @State private var isEditing = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            if isEditing {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($isFocused)
                    // Focus after the field exists: setting it in the same
                    // transaction that inserts the view often doesn't take,
                    // leaving the row stuck in edit mode.
                    .onAppear { isFocused = true }
                    .onSubmit { commit() }
                    .onChange(of: isFocused) { _, focused in
                        if !focused { commit() }
                    }
            } else {
                Text(profile.name)
                    .font(.system(size: 12))
                Text("\(profile.sampleCount) sample\(profile.sampleCount == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                if isHere {
                    HStack(spacing: 3) {
                        Image(systemName: "waveform")
                            .font(.system(size: 9))
                        Text("here")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(Color.accentColor)
                }
                Button {
                    draft = profile.name
                    isEditing = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Rename this voice")
                Button {
                    onForget()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Forget this voice (removes it from the library)")
            }
        }
        .contextMenu {
            Button("Rename") {
                draft = profile.name
                isEditing = true
            }
            Button("Forget This Voice", role: .destructive) { onForget() }
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed != profile.name {
            onRename(trimmed)
        }
        isEditing = false
    }
}

/// One detected-speaker row: color dot, editable name, and where the current
/// label came from (you / matched from the library / unnamed voice).
private struct LiveSpeakerNameRow: View {
    let speaker: Speaker
    let userName: String?
    let autoName: String?
    var suggestions: [String] = []
    var onAssignToMe: (() -> Void)? = nil
    let onCommit: (String) -> Void

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(speaker.color)
                    .frame(width: 7, height: 7)
                TextField(autoName ?? speaker.displayLabel, text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($isFocused)
                    .onSubmit { commitIfChanged() }
                    .onChange(of: isFocused) { _, focused in
                        if !focused { commitIfChanged() }
                    }
                    .onChange(of: userName) { _, newValue in
                        // Resync when the name changes underneath us (another
                        // surface renamed, or the assignment was cleared) so a
                        // stale draft can't be committed on blur.
                        if !isFocused { draft = newValue ?? "" }
                    }
                if !suggestions.isEmpty {
                    Menu {
                        ForEach(suggestions, id: \.self) { name in
                            Button(name) {
                                draft = name
                                onCommit(name)
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Pick from calendar invitees and saved voices")
                }
                if let onAssignToMe {
                    Button {
                        onAssignToMe()
                    } label: {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("This is me — this voice is you, not a guest")
                }
            }
            .contextMenu {
                if let onAssignToMe {
                    Button("This Is Me") { onAssignToMe() }
                }
            }
            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.leading, 13)
        }
        .onAppear { draft = userName ?? "" }
    }

    /// Commit only real changes: popover dismissal blurs every row, and a
    /// no-op commit would still fire the rename/pin path for each speaker.
    private func commitIfChanged() {
        guard draft != (userName ?? "") else { return }
        onCommit(draft)
    }

    private var caption: String {
        if speaker == .you { return "you" }
        if let userName, !userName.isEmpty { return "named by you" }
        if autoName != nil { return "matched from your saved voices" }
        switch speaker {
        case .them, .remote: return "on the call"
        default: return "in-person voice, listening for a match"
        }
    }
}
