import Foundation

/// The user's enrolled voice profile: a speaker embedding extracted from a short
/// recording, used to auto-label their own voice during mic diarization.
struct VoiceprintProfile: Codable {
    let embedding: [Float]
    let createdAt: Date
    let sampleDuration: Double
}

/// Persists the voice profile as JSON under Application Support. The embedding
/// never leaves this Mac; deleting the file removes the profile entirely.
enum VoiceprintStore {
    static func profileURL(appSupportDirectory: URL? = nil) -> URL {
        let fileManager = FileManager.default
        let appSupport =
            appSupportDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return appSupport
            .appendingPathComponent("OpenOats", isDirectory: true)
            .appendingPathComponent("VoiceProfile", isDirectory: true)
            .appendingPathComponent("voiceprint.json")
    }

    static var isEnrolled: Bool {
        FileManager.default.fileExists(atPath: profileURL().path)
    }

    static func load() -> VoiceprintProfile? {
        guard let data = try? Data(contentsOf: profileURL()) else { return nil }
        do {
            return try JSONDecoder.iso8601Decoder.decode(VoiceprintProfile.self, from: data)
        } catch {
            Log.diarization.error("Failed to decode voiceprint profile: \(error, privacy: .public)")
            return nil
        }
    }

    static func save(_ profile: VoiceprintProfile) throws {
        let url = profileURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(profile).write(to: url, options: .atomic)
    }

    static func delete() {
        try? FileManager.default.removeItem(at: profileURL())
    }
}
