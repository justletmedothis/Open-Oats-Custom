import XCTest
@testable import OpenOatsKit

/// The dense display numbering behind live Speaker A/B/C letters: raw
/// streaming-diarizer slots are arbitrary, so letters must mint in speaking
/// order, honor the in-room cap by folding, and survive merges without ever
/// reusing a number.
final class LiveSpeakerIndexerTests: XCTestCase {
    func testMintsDenseNumbersInAppearanceOrder() {
        var indexer = LiveSpeakerIndexer()
        // The field failure: the first guest of a meeting landed on raw slot
        // 3 and showed as "Speaker C" with no A or B in sight.
        XCTAssertEqual(indexer.displayIndex(forGuestSlot: 3), 1)
        XCTAssertEqual(indexer.displayIndex(forGuestSlot: 7), 2)
        XCTAssertEqual(indexer.displayIndex(forGuestSlot: 3), 1, "same slot keeps its number")
        XCTAssertEqual(indexer.display(forSlot: 7), 2)
        XCTAssertEqual(indexer.slot(forDisplay: 2), 7)
    }

    func testCapFoldsNewSlotIntoPreferredTarget() {
        var indexer = LiveSpeakerIndexer()
        XCTAssertEqual(indexer.displayIndex(forGuestSlot: 3, maxGuests: 1), 1)
        // At the cap, a new slot folds into the diarizer-suggested target
        // and stays folded while the cap holds.
        XCTAssertEqual(indexer.displayIndex(forGuestSlot: 5, maxGuests: 1, preferredFoldSlot: 3), 1)
        XCTAssertEqual(indexer.displayIndex(forGuestSlot: 5, maxGuests: 1), 1)
        XCTAssertEqual(indexer.guestDisplayCount, 1)
    }

    func testRaisingCapUnfoldsFoldedVoice() {
        var indexer = LiveSpeakerIndexer()
        // The field failure: stepper at 2 (one guest once self is known), a
        // third voice appears and folds into Speaker A — then the stepper
        // goes to 3 and the voice must split off, not stay glued to A.
        indexer.markSelf(slot: 1)
        XCTAssertEqual(indexer.displayIndex(forGuestSlot: 2, maxGuests: 1), 1)
        XCTAssertEqual(indexer.displayIndex(forGuestSlot: 4, maxGuests: 1, preferredFoldSlot: 2), 1)
        XCTAssertEqual(indexer.displayIndex(forGuestSlot: 4, maxGuests: 2), 2, "raised cap frees the folded voice")
        XCTAssertEqual(indexer.displayIndex(forGuestSlot: 4, maxGuests: 2), 2, "and it keeps its own letter")
        XCTAssertEqual(indexer.guestDisplayCount, 2)
        // Speaker A is untouched.
        XCTAssertEqual(indexer.displayIndex(forGuestSlot: 2, maxGuests: 2), 1)
    }

    func testCapFoldsIntoMostRecentGuestWithoutPreferredTarget() {
        var indexer = LiveSpeakerIndexer()
        XCTAssertEqual(indexer.displayIndex(forGuestSlot: 1, maxGuests: 2), 1)
        XCTAssertEqual(indexer.displayIndex(forGuestSlot: 4, maxGuests: 2), 2)
        // Slot 4 spoke last, so an unattributable new slot folds into it.
        XCTAssertEqual(indexer.displayIndex(forGuestSlot: 9, maxGuests: 2), 2)
    }

    func testSelfSlotsDontCountAgainstGuestCap() {
        var indexer = LiveSpeakerIndexer()
        // The user's voice lettered provisionally, then confirmed as self.
        XCTAssertEqual(indexer.displayIndex(forGuestSlot: 2, maxGuests: 2), 1)
        indexer.markSelf(slot: 2)
        XCTAssertTrue(indexer.hasKnownSelf)
        XCTAssertEqual(indexer.guestDisplayCount, 0)
        // A real guest still mints its own letter (cap = expected - self).
        XCTAssertEqual(indexer.displayIndex(forGuestSlot: 6, maxGuests: 1), 2)
        // And the next spurious slot folds into the guest, never into self.
        XCTAssertEqual(indexer.displayIndex(forGuestSlot: 8, maxGuests: 1, preferredFoldSlot: 2), 2)
    }

    func testCapWithNoGuestTargetStillMints() {
        var indexer = LiveSpeakerIndexer()
        indexer.markSelf(slot: 1)
        // Expected 1 (just the user) but a distinct voice appears: minting a
        // letter beats mislabeling it as the user.
        XCTAssertEqual(indexer.displayIndex(forGuestSlot: 4, maxGuests: 0), 1)
    }

    func testNoCapMintsFreely() {
        var indexer = LiveSpeakerIndexer()
        XCTAssertEqual(indexer.displayIndex(forGuestSlot: 1, maxGuests: 1), 1)
        // Library matches bypass the cap (positive evidence of a person).
        XCTAssertEqual(indexer.displayIndex(forGuestSlot: 6, maxGuests: nil), 2)
    }

    func testMergeRetiresDisplayAndRoutesFutureAudio() {
        var indexer = LiveSpeakerIndexer()
        XCTAssertEqual(indexer.displayIndex(forGuestSlot: 2), 1)
        XCTAssertEqual(indexer.displayIndex(forGuestSlot: 5), 2)
        XCTAssertTrue(indexer.merge(display: 2, into: 1))
        XCTAssertEqual(indexer.guestDisplayCount, 1)
        XCTAssertNil(indexer.slot(forDisplay: 2), "merged letter retires")
        XCTAssertEqual(indexer.displayIndex(forGuestSlot: 5), 1, "merged slot's audio flows to the survivor")
        // A genuinely new voice never reuses the retired number.
        XCTAssertEqual(indexer.displayIndex(forGuestSlot: 9), 3)
    }

    func testMergeRewritesExistingFolds() {
        var indexer = LiveSpeakerIndexer()
        XCTAssertEqual(indexer.displayIndex(forGuestSlot: 2), 1)
        XCTAssertEqual(indexer.displayIndex(forGuestSlot: 5), 2)
        // Slot 8 folded into slot 5 under a cap...
        XCTAssertEqual(indexer.displayIndex(forGuestSlot: 8, maxGuests: 2, preferredFoldSlot: 5), 2)
        // ...then Speaker B merged into Speaker A: while the cap still
        // holds, 8's fold must follow the survivor, not the retired letter.
        XCTAssertTrue(indexer.merge(display: 2, into: 1))
        XCTAssertEqual(indexer.displayIndex(forGuestSlot: 8, maxGuests: 1), 1)
        // With headroom the folded voice splits off as usual.
        XCTAssertEqual(indexer.displayIndex(forGuestSlot: 8, maxGuests: 2), 3)
    }

    func testMergeRejectsInvalidPairs() {
        var indexer = LiveSpeakerIndexer()
        XCTAssertEqual(indexer.displayIndex(forGuestSlot: 1), 1)
        XCTAssertFalse(indexer.merge(display: 1, into: 1))
        XCTAssertFalse(indexer.merge(display: 1, into: 9), "unknown target")
        XCTAssertFalse(indexer.merge(display: 9, into: 1), "unknown source")
    }

    func testMarkNotSelfReversesMarkSelf() {
        var indexer = LiveSpeakerIndexer()
        XCTAssertEqual(indexer.displayIndex(forGuestSlot: 3), 1)
        indexer.markSelf(slot: 3)
        XCTAssertEqual(indexer.guestDisplayCount, 0)
        indexer.markNotSelf(slot: 3)
        XCTAssertFalse(indexer.hasKnownSelf)
        XCTAssertEqual(indexer.guestDisplayCount, 1)
    }
}

/// Matcher-side merge semantics: user-granted evidence follows the survivor.
final class LiveVoiceMatcherMergeTests: XCTestCase {
    func testMergeCarriesThisIsMePinToSurvivor() async {
        let matcher = LiveVoiceMatcher(voiceprint: nil, profiles: [])
        await matcher.markSelf(localSpeakerNumber: 3)
        await matcher.mergeCluster(from: 3, into: 1)
        // The survivor is now pinned self: its utterances say "You".
        let verdict = await matcher.classifyUtterance(
            localSpeakerNumber: 1, startTime: 0, endTime: 1
        )
        XCTAssertEqual(verdict, .isSelf)
    }

    func testMergeCarriesUserAssignmentPinToSurvivor() async {
        let matcher = LiveVoiceMatcher(voiceprint: nil, profiles: [])
        await matcher.markAssignedByUser(localSpeakerNumber: 2)
        await matcher.mergeCluster(from: 2, into: 5)
        // The survivor inherits the pin: decided, not self, no auto name.
        let verdict = await matcher.classifyUtterance(
            localSpeakerNumber: 5, startTime: 0, endTime: 1
        )
        XCTAssertEqual(verdict, .notSelf)
    }
}
