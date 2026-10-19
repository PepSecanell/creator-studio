import XCTest

final class TeleprompterScriptTests: XCTestCase {

    func testVoiceoverLinesAreSplitOff() {
        let parts = TeleprompterScript.segments("Hello there.\n[VOICEOVER]Not for you.[/VOICEOVER]\nBack to you.")
        XCTAssertEqual(parts.map(\.isVoiceover), [false, true, false])
        XCTAssertEqual(parts[1].text, "Not for you.")
    }

    func testAnUnclosedVoiceoverRunsToTheEnd() {
        let parts = TeleprompterScript.segments("Start.[VOICEOVER]Never closed")
        XCTAssertEqual(parts.last?.isVoiceover, true)
        XCTAssertEqual(parts.last?.text, "Never closed")
    }

    func testCueLinesNeedAKeywordAndAGap() {
        XCTAssertEqual(TeleprompterScript.cueLine("SHOW  Open the dashboard")?.keyword, "SHOW")
        XCTAssertNil(TeleprompterScript.cueLine("DOING it now"))
        XCTAssertNil(TeleprompterScript.cueLine("SHOWER"))
    }

    func testCuesStyleKeepsEveryLineOnItsOwn() {
        let blocks = TeleprompterScript.blocks("First point\n\nSecond point", style: .cues)
        XCTAssertEqual(blocks.count, 2)
    }
}
