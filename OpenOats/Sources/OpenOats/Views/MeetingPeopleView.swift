import SwiftUI

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
                    let count = MeetingPeopleView.orderedSpeakers(in: state.liveTranscript).count
                    if count > 0 {
                        Text("\(count)")
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
        Self.nameSuggestions(
            invitees: state.matchedCalendarEvent?.participants.compactMap(\.displayName) ?? [],
            savedVoices: library.map(\.name),
            assignedNames: Array(state.displaySpeakerNames.values)
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
                    LiveSpeakerNameRow(
                        speaker: speaker,
                        userName: state.liveSpeakerNames[speaker.storageKey],
                        autoName: state.liveAutoSpeakerNames[speaker.storageKey],
                        suggestions: speaker == .you ? [] : nameSuggestions,
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
        }
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
                    HStack(spacing: 6) {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(profile.name)
                            .font(.system(size: 12))
                        Text("\(profile.sampleCount) sample\(profile.sampleCount == 1 ? "" : "s")")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        if state.isRunning, isInMeeting(profile.name) {
                            HStack(spacing: 3) {
                                Image(systemName: "waveform")
                                    .font(.system(size: 9))
                                Text("here")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }

            Text("Manage saved voices in Settings > Transcription > People.")
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

/// One detected-speaker row: color dot, editable name, and where the current
/// label came from (you / matched from the library / unnamed voice).
private struct LiveSpeakerNameRow: View {
    let speaker: Speaker
    let userName: String?
    let autoName: String?
    var suggestions: [String] = []
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
                    .onSubmit { onCommit(draft) }
                    .onChange(of: isFocused) { _, focused in
                        if !focused { onCommit(draft) }
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
            }
            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.leading, 13)
        }
        .onAppear { draft = userName ?? "" }
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
