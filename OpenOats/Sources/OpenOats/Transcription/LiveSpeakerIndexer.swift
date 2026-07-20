import Foundation

/// Maps the streaming diarizer's raw speaker indices onto the dense, stable
/// display numbers the rest of the app shows as Speaker A, B, C…
///
/// The LS-EEND streaming diarizer assigns utterances to internal speaker
/// slots whose numbers are arbitrary: the first guest of a meeting can land
/// on slot 3 (showing up as "Speaker C" with no A or B in sight), and one
/// real person can bounce across several slots. Display numbers are minted
/// here in order of first appearance instead, and a voice keeps its number
/// for the whole session. Numbers are never reused, even after a merge, so
/// a stale reference can't silently point at a different person.
///
/// The expected in-room people count (the People stepper) becomes a live
/// cap: once the allowed number of lettered guests exists, a new slot is
/// folded into an existing voice (a permanent alias) instead of minting
/// another letter. Slots confirmed as the user's own voice don't count
/// against the guest cap. All slot and display numbers are 1-based.
struct LiveSpeakerIndexer: Sendable {
    /// Display number by canonical slot.
    private var displayBySlot: [Int: Int] = [:]
    private var slotByDisplay: [Int: Int] = [:]
    /// Permanent slot aliases from user merges, kept flattened so
    /// resolution is single-hop.
    private var mergedBySlot: [Int: Int] = [:]
    /// Cap folds: slots sharing another voice's letter only because the
    /// in-room cap was reached when they appeared. Unlike merges these are
    /// re-evaluated on every utterance, so raising the stepper mid-meeting
    /// lets a folded voice split off and mint its own letter from then on.
    private var foldBySlot: [Int: Int] = [:]
    /// Canonical slots confirmed to be the user's voice.
    private var selfSlots: Set<Int> = []
    /// Canonical slot of the most recent lettered guest utterance; the fold
    /// target when the diarizer timeline offers no better candidate.
    private var lastGuestSlot: Int?
    /// Highest display number ever minted; merges never lower it.
    private var highestDisplay = 0

    /// Resolves a raw diarizer slot through user merges. Cap folds are NOT
    /// followed here: a folded slot keeps its own identity (the voice
    /// matcher scores it separately) and only shares a letter while the cap
    /// forces it to.
    func canonicalSlot(_ slot: Int) -> Int {
        mergedBySlot[slot] ?? slot
    }

    /// The canonical slot behind an active display number.
    func slot(forDisplay display: Int) -> Int? {
        slotByDisplay[display]
    }

    /// The display number a slot currently shows under, if any.
    func display(forSlot slot: Int) -> Int? {
        displayBySlot[canonicalSlot(slot)]
    }

    /// Whether any slot has been confirmed as the user's voice.
    var hasKnownSelf: Bool { !selfSlots.isEmpty }

    /// How many active display numbers belong to guests (not the user).
    var guestDisplayCount: Int {
        displayBySlot.keys.count { !selfSlots.contains($0) }
    }

    /// Active canonical slots currently displayed as guests.
    var displayedGuestSlots: [Int] {
        displayBySlot.keys.filter { !selfSlots.contains($0) }
    }

    /// Marks a slot as the user's voice: it stops counting against the
    /// guest cap and is never offered as a fold target.
    mutating func markSelf(slot: Int) {
        selfSlots.insert(canonicalSlot(slot))
    }

    /// Reverses markSelf (live "Not me" correction).
    mutating func markNotSelf(slot: Int) {
        selfSlots.remove(canonicalSlot(slot))
    }

    /// Display number for a guest utterance from `slot`. Mints the next
    /// dense number on first appearance; when `maxGuests` is reached, the
    /// new slot instead folds into `preferredFoldSlot` (falling back to the
    /// most recent, then the first-lettered, guest). Folds hold only while
    /// the cap forces them: once there's headroom again (the stepper was
    /// raised, a merge freed a letter, or the caller bypasses the cap), a
    /// folded slot splits off and mints its own letter. A cap with no
    /// existing guest to fold into still mints — a distinct voice is better
    /// shown under a new letter than mislabeled.
    mutating func displayIndex(
        forGuestSlot slot: Int,
        maxGuests: Int? = nil,
        preferredFoldSlot: Int? = nil
    ) -> Int {
        let canonical = canonicalSlot(slot)
        if let display = displayBySlot[canonical] {
            if !selfSlots.contains(canonical) { lastGuestSlot = canonical }
            return display
        }
        let atCap = maxGuests.map { guestDisplayCount >= $0 } ?? false
        if let foldTarget = foldBySlot[canonical].map({ canonicalSlot($0) }) {
            if atCap, let display = displayBySlot[foldTarget] {
                lastGuestSlot = foldTarget
                return display
            }
            // Headroom now: stop following the fold and mint below.
            foldBySlot[canonical] = nil
        }
        if atCap {
            let firstLettered = displayedGuestSlots.min { lhs, rhs in
                (displayBySlot[lhs] ?? .max) < (displayBySlot[rhs] ?? .max)
            }
            let target = [preferredFoldSlot.map { canonicalSlot($0) }, lastGuestSlot, firstLettered]
                .compactMap { $0 }
                .first { displayBySlot[$0] != nil && !selfSlots.contains($0) }
            if let target {
                foldBySlot[canonical] = target
                lastGuestSlot = target
                return displayBySlot[target]!
            }
        }
        highestDisplay += 1
        displayBySlot[canonical] = highestDisplay
        slotByDisplay[highestDisplay] = canonical
        lastGuestSlot = canonical
        return highestDisplay
    }

    /// Merges one displayed voice into another (the user says they're the
    /// same person). The merged display number retires for the rest of the
    /// session and future audio on its slot flows to the survivor. Returns
    /// false when either number isn't active or they're equal.
    @discardableResult
    mutating func merge(display from: Int, into: Int) -> Bool {
        guard from != into,
              let fromSlot = slotByDisplay[from],
              let intoSlot = slotByDisplay[into] else { return false }
        for (slot, target) in mergedBySlot where target == fromSlot {
            mergedBySlot[slot] = intoSlot
        }
        for (slot, target) in foldBySlot where canonicalSlot(target) == fromSlot {
            foldBySlot[slot] = intoSlot
        }
        mergedBySlot[fromSlot] = intoSlot
        foldBySlot.removeValue(forKey: fromSlot)
        displayBySlot.removeValue(forKey: fromSlot)
        slotByDisplay.removeValue(forKey: from)
        if selfSlots.remove(fromSlot) != nil { selfSlots.insert(intoSlot) }
        if lastGuestSlot == fromSlot { lastGuestSlot = intoSlot }
        return true
    }
}
