import XCTest
@testable import OpenOatsKit

final class SpeakerLibraryTests: XCTestCase {
    private func profile(name: String, centroid: [Float]) -> SpeakerProfile {
        SpeakerProfile(
            id: UUID(),
            name: name,
            centroid: centroid,
            sampleCount: 1,
            createdAt: .now,
            updatedAt: .now
        )
    }

    // Orthogonal unit vectors have cosine distance 1; identical vectors 0.
    func testMatchAcceptsCloseVoiceRejectsFar() {
        let matt = profile(name: "Matt", centroid: [1, 0, 0])
        let dana = profile(name: "Dana", centroid: [0, 1, 0])
        let profiles = [matt, dana]

        XCTAssertEqual(SpeakerLibraryStore.match(embedding: [1, 0, 0], in: profiles)?.name, "Matt")
        XCTAssertNil(SpeakerLibraryStore.match(embedding: [0, 0, 1], in: profiles), "orthogonal voice must not match")
    }

    func testMatchRejectsAmbiguousRunnerUp() {
        // Two nearly identical profiles: best match wins on distance but the
        // runner-up gap is under the margin, so no auto-name.
        let a = profile(name: "A", centroid: [1, 0, 0])
        let b = profile(name: "B", centroid: [0.999, 0.0447, 0])
        XCTAssertNil(SpeakerLibraryStore.match(embedding: [1, 0, 0], in: [a, b]))
    }

    func testMatchEmptyLibrary() {
        XCTAssertNil(SpeakerLibraryStore.match(embedding: [1, 0, 0], in: []))
    }

    // MARK: - Batch naming policy (resolveLibraryNaming)

    // A voice the user named this session is enrolled into the library, even
    // when the library is empty — this is the fix for names not surviving into
    // the next meeting. (Naming a speaker used to persist only the session
    // label, never the voiceprint.)
    func testUserNamedVoiceIsEnrolledEvenWithEmptyLibrary() {
        let resolution = BatchAudioTranscriber.resolveLibraryNaming(
            embeddings: ["local_1": [1, 0, 0]],
            userNames: ["local_1": "Matt"],
            profiles: []
        )
        XCTAssertEqual(resolution.enrollments, [.init(name: "Matt", embedding: [1, 0, 0])])
        XCTAssertTrue(resolution.autoNames.isEmpty, "user-named speakers are enrolled, not auto-named")
    }

    // An un-named voice recognized from the library is auto-named and reinforced.
    func testRecognizedVoiceIsAutoNamedAndReinforced() {
        let profiles = [profile(name: "Dana", centroid: [1, 0, 0])]
        let resolution = BatchAudioTranscriber.resolveLibraryNaming(
            embeddings: ["local_1": [1, 0, 0]],
            userNames: [:],
            profiles: profiles
        )
        XCTAssertEqual(resolution.autoNames, ["local_1": "Dana"])
        XCTAssertEqual(resolution.enrollments, [.init(name: "Dana", embedding: [1, 0, 0])])
    }

    // A user name always wins over a library match for the same voice.
    func testUserNameOverridesLibraryMatch() {
        let profiles = [profile(name: "Dana", centroid: [1, 0, 0])]
        let resolution = BatchAudioTranscriber.resolveLibraryNaming(
            embeddings: ["local_1": [1, 0, 0]],
            userNames: ["local_1": "Matt"],
            profiles: profiles
        )
        XCTAssertEqual(resolution.enrollments, [.init(name: "Matt", embedding: [1, 0, 0])])
        XCTAssertTrue(resolution.autoNames.isEmpty)
    }

    // An unrecognized, un-named voice is left alone (no enrollment, no name).
    func testUnknownUnnamedVoiceIsUntouched() {
        let profiles = [profile(name: "Dana", centroid: [1, 0, 0])]
        let resolution = BatchAudioTranscriber.resolveLibraryNaming(
            embeddings: ["local_1": [0, 0, 1]],
            userNames: [:],
            profiles: profiles
        )
        XCTAssertTrue(resolution.enrollments.isEmpty)
        XCTAssertTrue(resolution.autoNames.isEmpty)
    }

    // Blank/whitespace names are ignored rather than enrolled.
    func testBlankUserNameIsNotEnrolled() {
        let resolution = BatchAudioTranscriber.resolveLibraryNaming(
            embeddings: ["local_1": [1, 0, 0]],
            userNames: ["local_1": "   "],
            profiles: []
        )
        XCTAssertTrue(resolution.enrollments.isEmpty)
        XCTAssertTrue(resolution.autoNames.isEmpty)
    }
}

final class VoiceprintReinforcementTests: XCTestCase {
    func testBlendWeightsExistingBySampleCount() {
        // 3 prior samples at [1,0], one new at [0,1]: pre-normalization mean is
        // [0.75, 0.25], so the blend must stay much closer to the existing axis.
        let blended = VoiceprintStore.blendedCentroid(existing: [1, 0], count: 3, new: [0, 1])
        XCTAssertGreaterThan(blended[0], blended[1] * 2)

        let norm = sqrt(blended.reduce(0) { $0 + $1 * $1 })
        XCTAssertEqual(norm, 1.0, accuracy: 0.0001, "blend must stay a unit vector")
    }

    func testBlendOfIdenticalVectorsIsStable() {
        let blended = VoiceprintStore.blendedCentroid(existing: [0.6, 0.8], count: 5, new: [0.6, 0.8])
        XCTAssertEqual(blended[0], 0.6, accuracy: 0.0001)
        XCTAssertEqual(blended[1], 0.8, accuracy: 0.0001)
    }
}

final class VocabularyRewriterTests: XCTestCase {
    func testRewritesAliasesCaseInsensitively() {
        let rewriter = VocabularyRewriter("OpenOats: open oats, open notes\nJiz\nHermes")
        XCTAssertEqual(rewriter.rewrite("I use Open Notes daily"), "I use OpenOats daily")
        XCTAssertEqual(rewriter.rewrite("open oats is running"), "OpenOats is running")
    }

    func testBareHotwordLinesAreIgnored() {
        let rewriter = VocabularyRewriter("Jiz\nHermes")
        XCTAssertTrue(rewriter.isEmpty)
        XCTAssertEqual(rewriter.rewrite("jiz and hermes"), "jiz and hermes")
    }

    func testWordBoundariesRespected() {
        let rewriter = VocabularyRewriter("Onni: on")
        XCTAssertEqual(rewriter.rewrite("turn it on"), "turn it Onni")
        XCTAssertEqual(rewriter.rewrite("keep going strong"), "keep going strong", "no substring hits inside words")
    }

    func testMultipleAliasesFromRealConfig() {
        let rewriter = VocabularyRewriter("Matt Feduik: map fiduke")
        XCTAssertEqual(rewriter.rewrite("Ask map fiduke about it"), "Ask Matt Feduik about it")
    }
}
