import Foundation

// MARK: - Speaker

enum Speaker: Codable, Sendable, Hashable {
    case you
    case them
    case remote(Int)
    /// Diarized speaker on the microphone channel (in-person participants).
    /// Lettered labels so they never collide with numbered remote speakers.
    case local(Int)

    var displayLabel: String {
        switch self {
        case .you: "You"
        case .them: "Them"
        case .remote(let n): "Speaker \(n)"
        case .local(let n): "Speaker \(Self.letter(for: n))"
        }
    }

    /// A, B, ... Z, then AA, AB, ... for the unlikely n > 26.
    private static func letter(for n: Int) -> String {
        var value = max(n, 1) - 1
        var result = ""
        repeat {
            result = String(UnicodeScalar(UInt8(65 + value % 26))) + result
            value = value / 26 - 1
        } while value >= 0
        return result
    }

    func displayName(speakerNames: [String: String]?) -> String {
        speakerNames?[storageKey] ?? displayLabel
    }

    /// True for any system-audio speaker (.them or .remote).
    var isRemote: Bool {
        switch self {
        case .you, .local: false
        case .them, .remote: true
        }
    }

    /// Speakers whose label is a guess the user may want to replace with a name.
    var isRenameable: Bool {
        self != .you
    }

    /// Stable key for persistence (JSONL encoding, backfill dedup).
    var storageKey: String {
        switch self {
        case .you: "you"
        case .them: "them"
        case .remote(let n): "remote_\(n)"
        case .local(let n): "local_\(n)"
        }
    }

    // MARK: - Codable

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "you": self = .you
        case "them": self = .them
        default:
            if raw.hasPrefix("remote_"), let n = Int(raw.dropFirst("remote_".count)) {
                self = .remote(n)
            } else if raw.hasPrefix("local_"), let n = Int(raw.dropFirst("local_".count)) {
                self = .local(n)
            } else {
                self = .them
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storageKey)
    }
}

// MARK: - Audio Source

/// Which capture channel produced an utterance. Distinct from Speaker: the
/// speaker label can be rewritten by diarization/renames, while the source is
/// a physical fact about where the audio came from.
enum AudioSource: String, Codable, Sendable {
    /// Local microphone (the user's side of the room).
    case microphone
    /// System-audio tap (remote meeting participants, media playback).
    case system
}

// MARK: - Text Cleanup Status

enum TextCleanupStatus: String, Codable, Sendable {
    case pending, completed, failed, skipped
}

// MARK: - Utterance

struct Utterance: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let text: String
    let speaker: Speaker
    let timestamp: Date
    let cleanedText: String?
    let cleanupStatus: TextCleanupStatus?
    /// Segment start/end in seconds relative to the recording start.
    /// Present for live segments transcribed after timestamps were introduced.
    let startTime: TimeInterval?
    let endTime: TimeInterval?
    /// Capture channel that produced this utterance.
    let source: AudioSource?

    enum CodingKeys: String, CodingKey {
        case id, text, speaker, timestamp
        case cleanedText = "refinedText"
        case cleanupStatus = "refinementStatus"
        case startTime, endTime, source
    }

    init(
        text: String,
        speaker: Speaker,
        timestamp: Date = .now,
        cleanedText: String? = nil,
        cleanupStatus: TextCleanupStatus? = nil,
        startTime: TimeInterval? = nil,
        endTime: TimeInterval? = nil,
        source: AudioSource? = nil
    ) {
        self.id = UUID()
        self.text = text
        self.speaker = speaker
        self.timestamp = timestamp
        self.cleanedText = cleanedText
        self.cleanupStatus = cleanupStatus
        self.startTime = startTime
        self.endTime = endTime
        self.source = source
    }

    /// The best available text: cleaned if available, otherwise raw.
    var displayText: String {
        cleanedText ?? text
    }

    func withCleanup(text: String?, status: TextCleanupStatus) -> Utterance {
        Utterance(
            id: self.id,
            text: self.text,
            speaker: self.speaker,
            timestamp: self.timestamp,
            cleanedText: text,
            cleanupStatus: status,
            startTime: self.startTime,
            endTime: self.endTime,
            source: self.source
        )
    }

    /// Same utterance (same ID) with a rewritten speaker label — used when
    /// live voiceprint matching identifies an already-lettered speaker.
    func withSpeaker(_ newSpeaker: Speaker) -> Utterance {
        Utterance(
            id: self.id,
            text: self.text,
            speaker: newSpeaker,
            timestamp: self.timestamp,
            cleanedText: self.cleanedText,
            cleanupStatus: self.cleanupStatus,
            startTime: self.startTime,
            endTime: self.endTime,
            source: self.source
        )
    }

    /// Private memberwise init that preserves an existing ID.
    private init(
        id: UUID,
        text: String,
        speaker: Speaker,
        timestamp: Date,
        cleanedText: String?,
        cleanupStatus: TextCleanupStatus?,
        startTime: TimeInterval?,
        endTime: TimeInterval?,
        source: AudioSource?
    ) {
        self.id = id
        self.text = text
        self.speaker = speaker
        self.timestamp = timestamp
        self.cleanedText = cleanedText
        self.cleanupStatus = cleanupStatus
        self.startTime = startTime
        self.endTime = endTime
        self.source = source
    }
}

// MARK: - Conversation State

struct ConversationState: Sendable, Codable {
    var currentTopic: String
    var shortSummary: String
    var openQuestions: [String]
    var activeTensions: [String]
    var recentDecisions: [String]
    var themGoals: [String]
    var suggestedAnglesRecentlyShown: [String]
    var lastUpdatedAt: Date

    static let empty = ConversationState(
        currentTopic: "",
        shortSummary: "",
        openQuestions: [],
        activeTensions: [],
        recentDecisions: [],
        themGoals: [],
        suggestedAnglesRecentlyShown: [],
        lastUpdatedAt: .distantPast
    )
}
