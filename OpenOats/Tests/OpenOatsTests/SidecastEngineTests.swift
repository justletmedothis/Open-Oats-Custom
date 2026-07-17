import XCTest
@testable import OpenOatsKit

@MainActor
final class SidecastEngineTests: XCTestCase {
    // MARK: - firstBalancedJSONObject

    func testExtractsSimpleObject() {
        let result = SidecastEngine.firstBalancedJSONObject(in: #"{"a":1}"#)
        XCTAssertEqual(result?.text, #"{"a":1}"#)
    }

    func testExtractsObjectWithProsePrefixAndSuffix() {
        let line = #"Sure! Here you go: {"speak":true,"text":"hi"} hope that helps"#
        let result = SidecastEngine.firstBalancedJSONObject(in: Substring(line))
        XCTAssertEqual(result?.text, #"{"speak":true,"text":"hi"}"#)
    }

    func testHandlesBracesInsideStrings() {
        let line = #"{"text":"a {nested} \"quote\" }brace"}"#
        let result = SidecastEngine.firstBalancedJSONObject(in: Substring(line))
        XCTAssertEqual(result?.text, line)
    }

    func testReturnsNilForUnbalancedObject() {
        XCTAssertNil(SidecastEngine.firstBalancedJSONObject(in: #"{"text":"unclosed"#))
        XCTAssertNil(SidecastEngine.firstBalancedJSONObject(in: "no json here"))
    }

    func testFindsSecondObjectViaRange() {
        let line = #"{"a":1} {"b":2}"#
        guard let first = SidecastEngine.firstBalancedJSONObject(in: Substring(line)) else {
            return XCTFail("expected first object")
        }
        let remainder = Substring(line)[first.range.upperBound...]
        let second = SidecastEngine.firstBalancedJSONObject(in: remainder)
        XCTAssertEqual(second?.text, #"{"b":2}"#)
    }

    // MARK: - decodeCandidate

    func testDecodesWellFormedCandidate() {
        let id = UUID()
        let json = #"{"persona_id":"\#(id.uuidString)","speak":true,"text":"hello","priority":0.8,"confidence":0.7,"value":0.9}"#
        let candidate = SidecastEngine.decodeCandidate(json)
        XCTAssertEqual(candidate?.personaID, id)
        XCTAssertEqual(candidate?.speak, true)
        XCTAssertEqual(candidate?.text, "hello")
        XCTAssertEqual(candidate?.priority, 0.8)
    }

    func testDecodesExplicitSilenceLine() {
        let candidate = SidecastEngine.decodeCandidate(#"{"speak":false}"#)
        XCTAssertNotNil(candidate)
        XCTAssertEqual(candidate?.speak, false)
        XCTAssertNil(candidate?.personaID)
    }

    func testNonUUIDPersonaIDFallsBackToName() {
        let candidate = SidecastEngine.decodeCandidate(#"{"persona_id":"the-checker","speak":true,"text":"hi"}"#)
        XCTAssertNil(candidate?.personaID)
        XCTAssertEqual(candidate?.personaName, "the-checker")
    }

    func testDecodesNameKeyedCandidate() {
        let candidate = SidecastEngine.decodeCandidate(#"{"name":"The Sniper","text":"zing"}"#)
        XCTAssertEqual(candidate?.personaName, "The Sniper")
        XCTAssertEqual(candidate?.speak, true, "speak should default to true when omitted")
    }

    func testRejectsLegacyWrapperObject() {
        XCTAssertNil(SidecastEngine.decodeCandidate(#"{"messages":[{"persona_id":"x","speak":true,"text":"hi"}]}"#))
    }

    func testRejectsNonObjectLines() {
        XCTAssertNil(SidecastEngine.decodeCandidate("```json"))
        XCTAssertNil(SidecastEngine.decodeCandidate(""))
        XCTAssertNil(SidecastEngine.decodeCandidate("[1,2,3]"))
    }
}
