import Foundation

/// The user's enrolled voice profile: a speaker embedding extracted from a short
/// recording, used to auto-label their own voice during mic diarization.
struct VoiceprintProfile: Codable {
    let embedding: [Float]
    let createdAt: Date
    let sampleDuration: Double
    /// Number of samples blended into `embedding` (nil = original single
    /// enrollment; older profiles decode without it).
    var sampleCount: Int? = nil
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

    /// Sanity ceiling for reinforcement: a corrected cluster whose embedding is
    /// farther than this from the current voiceprint is ignored rather than
    /// blended in, so one mistaken "this is me" can't poison the profile.
    static let maxReinforceDistance: Float = 0.65

    /// Blends a user-confirmed "this is me" cluster embedding into the enrolled
    /// voiceprint (weighted running mean). No-op when no profile is enrolled or
    /// the embedding fails the distance sanity check.
    @discardableResult
    static func reinforce(with embedding: [Float]) -> Bool {
        guard let profile = load(), profile.embedding.count == embedding.count else { return false }
        let distance = SelfVoiceIdentifier.distance(profile.embedding, embedding)
        guard distance <= maxReinforceDistance else {
            Log.diarization.info("Voiceprint reinforcement skipped: distance \(distance, privacy: .public) too far")
            return false
        }
        let count = profile.sampleCount ?? 1
        let blended = blendedCentroid(existing: profile.embedding, count: count, new: embedding)
        let updated = VoiceprintProfile(
            embedding: blended,
            createdAt: profile.createdAt,
            sampleDuration: profile.sampleDuration,
            sampleCount: count + 1
        )
        do {
            try save(updated)
            Log.diarization.info("Voiceprint reinforced (sample \(count + 1, privacy: .public), distance \(distance, privacy: .public))")
            return true
        } catch {
            Log.diarization.error("Voiceprint reinforcement failed to save: \(error, privacy: .public)")
            return false
        }
    }

    /// Weighted running mean of `existing` (weight `count`) and `new`
    /// (weight 1), L2-normalized to stay a valid unit embedding.
    static func blendedCentroid(existing: [Float], count: Int, new: [Float]) -> [Float] {
        let weight = Float(max(count, 1))
        var blended = zip(existing, new).map { ($0 * weight + $1) / (weight + 1) }
        let norm = sqrt(blended.reduce(0) { $0 + $1 * $1 })
        if norm > 0 {
            blended = blended.map { $0 / norm }
        }
        return blended
    }
}
