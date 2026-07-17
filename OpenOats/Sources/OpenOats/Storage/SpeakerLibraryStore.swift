import Foundation

/// A named voice in the persistent speaker library.
struct SpeakerProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    /// Running-mean, L2-normalized WeSpeaker embedding (256 floats ≈ 2 KB).
    var centroid: [Float]
    var sampleCount: Int
    let createdAt: Date
    var updatedAt: Date
}

/// Persistent library of named speaker voiceprints, stored next to the self
/// voice profile. Renaming "Speaker A" to a real name once (with "Remember
/// this voice") makes that person auto-named in future meetings. Everything
/// stays on this Mac; deleting a profile forgets the voice entirely.
enum SpeakerLibraryStore {
    /// Stricter than the self-voice ceiling (0.65): a wrong auto-name is worse
    /// than a letter the user can rename.
    static let maxMatchDistance: Float = 0.55
    /// Best profile must beat the runner-up by this margin.
    static let minRunnerUpGap: Float = 0.05

    static func libraryURL(appSupportDirectory: URL? = nil) -> URL {
        VoiceprintStore.profileURL(appSupportDirectory: appSupportDirectory)
            .deletingLastPathComponent()
            .appendingPathComponent("speakers.json")
    }

    static func load() -> [SpeakerProfile] {
        guard let data = try? Data(contentsOf: libraryURL()) else { return [] }
        do {
            return try JSONDecoder.iso8601Decoder.decode([SpeakerProfile].self, from: data)
        } catch {
            Log.diarization.error("Failed to decode speaker library: \(error, privacy: .public)")
            return []
        }
    }

    static func save(_ profiles: [SpeakerProfile]) {
        let url = libraryURL()
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(profiles).write(to: url, options: .atomic)
        } catch {
            Log.diarization.error("Failed to save speaker library: \(error, privacy: .public)")
        }
    }

    /// Add a voice sample for a name: merges into the existing profile of that
    /// name (running-mean centroid, so the voiceprint improves with every
    /// meeting) or creates a new profile.
    static func addSample(name: String, embedding: [Float]) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !embedding.isEmpty else { return }
        var profiles = load()
        if let index = profiles.firstIndex(where: { $0.name.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            var profile = profiles[index]
            profile.centroid = normalized(
                runningMean(profile.centroid, count: profile.sampleCount, adding: embedding)
            )
            profile.sampleCount += 1
            profile.updatedAt = .now
            profiles[index] = profile
        } else {
            profiles.append(
                SpeakerProfile(
                    id: UUID(),
                    name: trimmed,
                    centroid: normalized(embedding),
                    sampleCount: 1,
                    createdAt: .now,
                    updatedAt: .now
                )
            )
        }
        save(profiles)
    }

    static func rename(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var profiles = load()
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].name = trimmed
        profiles[index].updatedAt = .now
        save(profiles)
    }

    static func delete(id: UUID) {
        var profiles = load()
        profiles.removeAll { $0.id == id }
        save(profiles)
    }

    /// Best-matching profile for a voice embedding, or nil when no profile is
    /// a confident match (distance ceiling + runner-up margin, mirroring the
    /// batch self-voice semantics).
    static func match(embedding: [Float], in profiles: [SpeakerProfile]) -> SpeakerProfile? {
        let scored = profiles
            .map { (profile: $0, distance: SelfVoiceIdentifier.distance(embedding, $0.centroid)) }
            .filter { $0.distance.isFinite }
            .sorted { $0.distance < $1.distance }
        guard let best = scored.first, best.distance <= maxMatchDistance else { return nil }
        if scored.count > 1, scored[1].distance - best.distance < minRunnerUpGap { return nil }
        return best.profile
    }

    private static func runningMean(_ centroid: [Float], count: Int, adding embedding: [Float]) -> [Float] {
        guard centroid.count == embedding.count, count > 0 else { return embedding }
        let weight = Float(count)
        return zip(centroid, embedding).map { ($0 * weight + $1) / (weight + 1) }
    }

    private static func normalized(_ vector: [Float]) -> [Float] {
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }
}
