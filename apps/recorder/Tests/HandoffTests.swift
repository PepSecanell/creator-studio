import XCTest

final class HandoffTests: XCTestCase {

    private func data(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func valid(created: String = "2026-10-19T09:00:00Z") -> [String: Any] {
        [
            "schema": "handoff/v1", "kind": "short", "id": "w42-03", "title": "Ship it ugly",
            "mode": "cards", "teleprompter": "", "points": ["First point", " ", "Second point"],
            "out_dir": "/tmp/ws/takes/shorts/2026-10-19-w42-03-take-1",
            "created": created, "brand": "Northwind"
        ]
    }

    private let now = Handoff.parseDate("2026-10-19T10:00:00Z")!

    func testParsesAValidShortHandoff() throws {
        let handoff = try XCTUnwrap(Handoff.parse(data(valid()), now: now))
        XCTAssertEqual(handoff.kind, .short)
        XCTAssertEqual(handoff.id, "w42-03")
        XCTAssertEqual(handoff.mode, .cards)
        XCTAssertEqual(handoff.points, ["First point", "Second point"])
        XCTAssertEqual(handoff.prompterText, "First point\nSecond point")
        XCTAssertEqual(handoff.identity, "w42-03|2026-10-19T09:00:00Z")
        XCTAssertEqual(handoff.outDir?.lastPathComponent, "2026-10-19-w42-03-take-1")
    }

    func testIgnoresHandoffsOlderThanSixHours() {
        let old = "2026-10-19T03:00:00Z"
        XCTAssertNil(Handoff.parse(data(valid(created: old)), now: now))
    }

    func testIgnoresWrongSchemaMissingIdAndBadKind() {
        var wrongSchema = valid(); wrongSchema["schema"] = "other/v1"
        var noID = valid(); noID["id"] = " "
        var badKind = valid(); badKind["kind"] = "podcast"
        XCTAssertNil(Handoff.parse(data(wrongSchema), now: now))
        XCTAssertNil(Handoff.parse(data(noID), now: now))
        XCTAssertNil(Handoff.parse(data(badKind), now: now))
        XCTAssertNil(Handoff.parse(Data("not json".utf8), now: now))
    }

    func testScriptModeShowsTheTeleprompterText() throws {
        var object = valid()
        object["kind"] = "long"; object["mode"] = "script"; object["teleprompter"] = "Read this."
        let handoff = try XCTUnwrap(Handoff.parse(data(object), now: now))
        XCTAssertEqual(handoff.prompterText, "Read this.")
        XCTAssertEqual(handoff.prompterStyle, .script)
    }

    func testRelativeOutDirIsDropped() throws {
        var object = valid(); object["out_dir"] = "takes/shorts/x"
        XCTAssertNil(try XCTUnwrap(Handoff.parse(data(object), now: now)).outDir)
    }

    func testNewestUnusedHandoffWins() throws {
        let short = try XCTUnwrap(Handoff.parse(data(valid(created: "2026-10-19T09:00:00Z")), now: now))
        var longObject = valid(created: "2026-10-19T09:30:00Z")
        longObject["kind"] = "long"; longObject["id"] = "my-video"
        let long = try XCTUnwrap(Handoff.parse(data(longObject), now: now))

        XCTAssertEqual(HandoffArbiter.pick([short, long], used: []), long)
        XCTAssertEqual(HandoffArbiter.pick([short, long], used: [long.identity]), short)
        XCTAssertNil(HandoffArbiter.pick([short, long, nil], used: [short.identity, long.identity]))
    }

    func testLedgerRemembersUsedHandoffs() throws {
        let suite = UserDefaults(suiteName: "recorder-tests-\(UUID().uuidString)")!
        let ledger = HandoffLedger(defaults: suite, key: "used")
        let handoff = try XCTUnwrap(Handoff.parse(data(valid()), now: now))
        XCTAssertTrue(ledger.used.isEmpty)
        ledger.markUsed(handoff)
        ledger.markUsed(handoff)
        XCTAssertEqual(ledger.used, [handoff.identity])
    }
}
