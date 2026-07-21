import XCTest
@testable import OpenOatsKit

final class LiveChatPromptTests: XCTestCase {
    private let snapshotDate = Date(timeIntervalSince1970: 1_752_000_000)

    func testFormatSnapshotResolvesSpeakerNamesAndPrefersCleanedText() {
        let utterances = [
            Utterance(text: "Budget is approved", speaker: .them, timestamp: snapshotDate),
            Utterance(text: "grate news", speaker: .you, timestamp: snapshotDate, cleanedText: "Great news"),
            Utterance(text: "Timeline slips a week", speaker: .local(1), timestamp: snapshotDate),
        ]

        let snapshot = LiveChatPrompt.formatSnapshot(
            utterances: utterances,
            speakerNames: ["them": "Priya"],
            volatileYouText: "",
            volatileThemText: "",
            snapshotDate: snapshotDate
        )

        XCTAssertTrue(snapshot.contains("Priya: Budget is approved"))
        XCTAssertTrue(snapshot.contains("You: Great news"))
        XCTAssertTrue(snapshot.contains("Speaker A: Timeline slips a week"))
        XCTAssertTrue(snapshot.contains("Live transcript snapshot taken at"))
    }

    func testFormatSnapshotLabelsVolatileTextAsInProgress() {
        let snapshot = LiveChatPrompt.formatSnapshot(
            utterances: [Utterance(text: "So far", speaker: .you, timestamp: snapshotDate)],
            speakerNames: nil,
            volatileYouText: "and one more thing",
            volatileThemText: "  ",
            snapshotDate: snapshotDate
        )

        XCTAssertTrue(snapshot.contains("[in progress] You: and one more thing"))
        XCTAssertFalse(snapshot.contains("[in progress] Them:"))
    }

    func testFormatSnapshotWithNoSpeechSaysSo() {
        let snapshot = LiveChatPrompt.formatSnapshot(
            utterances: [],
            speakerNames: nil,
            volatileYouText: "",
            volatileThemText: "",
            snapshotDate: snapshotDate
        )

        XCTAssertTrue(snapshot.contains("No speech captured yet"))
    }

    func testTruncatedTranscriptOmitsTheMiddleBeyondLimit() {
        let long = String(repeating: "a", count: LiveChatPrompt.transcriptCharacterLimit + 100)

        let truncated = LiveChatPrompt.truncatedTranscript(long)

        XCTAssertTrue(truncated.contains("[Transcript truncated: middle omitted]"))
        XCTAssertLessThan(truncated.count, long.count)
        XCTAssertEqual(LiveChatPrompt.truncatedTranscript("short"), "short")
    }

    func testBuildMessagesOrdersSystemSnapshotHistoryQuestion() {
        let history = [
            LiveChatMessage(role: .user, text: "first question"),
            LiveChatMessage(role: .assistant, text: "first answer"),
        ]

        let messages = LiveChatPrompt.buildMessages(
            question: "second question",
            transcriptSnapshot: "SNAPSHOT",
            history: history
        )

        XCTAssertEqual(messages.map(\.role), ["system", "user", "user", "assistant", "user"])
        XCTAssertTrue(messages[1].content.contains("SNAPSHOT"))
        XCTAssertEqual(messages[2].content, "first question")
        XCTAssertEqual(messages[3].content, "first answer")
        XCTAssertEqual(messages.last?.content, "second question")
    }

    func testBuildMessagesCapsHistoryAtTwelveTurns() {
        let history = (0..<20).map { turn in
            LiveChatMessage(role: turn % 2 == 0 ? .user : .assistant, text: "turn \(turn)")
        }

        let messages = LiveChatPrompt.buildMessages(
            question: "latest",
            transcriptSnapshot: "snapshot",
            history: history
        )

        // system + snapshot + 12 most recent history turns + question
        XCTAssertEqual(messages.count, 15)
        XCTAssertEqual(messages[2].content, "turn 8")
        XCTAssertEqual(messages[13].content, "turn 19")
    }
}
