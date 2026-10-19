import XCTest

final class TakeFolderTests: XCTestCase {

    private var root: URL!
    private var workspace: Workspace!
    private let date = Date(timeIntervalSince1970: 1_792_400_000)   // 2026-10-19 in UTC

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recorder-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("takes"), withIntermediateDirectories: true)
        workspace = Workspace(config: StudioConfig(repo: nil, workspace: root))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func handoff(kind: String, id: String, outDir: String) -> Handoff {
        let object: [String: Any] = [
            "schema": "handoff/v1", "kind": kind, "id": id, "title": "T", "mode": "cards",
            "out_dir": outDir, "created": ISO8601DateFormatter().string(from: Date())
        ]
        return Handoff.parse(try! JSONSerialization.data(withJSONObject: object))!
    }

    private func make(_ url: URL) {
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func testHandoffOutDirInsideTakesIsUsed() {
        let out = workspace.shortsRoot.appendingPathComponent("2026-10-19-w1-01-take-1")
        let plan = TakePlanner.plan(kind: .short, handoff: handoff(kind: "short", id: "w1-01", outDir: out.path),
                                    videoFolder: nil, workspace: workspace, date: date)
        XCTAssertEqual(plan.folder.lastPathComponent, "2026-10-19-w1-01-take-1")
        XCTAssertEqual(plan.number, 1)
        XCTAssertEqual(plan.id, "w1-01")
    }

    func testUsedHandoffFolderCountsUp() throws {
        let first = workspace.shortsRoot.appendingPathComponent("2026-10-19-w1-01-take-1")
        make(first)
        FileManager.default.createFile(atPath: first.appendingPathComponent("take.json").path, contents: Data("{}".utf8))
        let plan = TakePlanner.plan(kind: .short, handoff: handoff(kind: "short", id: "w1-01", outDir: first.path),
                                    videoFolder: nil, workspace: workspace, date: date)
        XCTAssertEqual(plan.folder.lastPathComponent, "2026-10-19-w1-01-take-2")
        XCTAssertEqual(plan.number, 2)
    }

    func testOutDirOutsideTakesIsIgnored() {
        let plan = TakePlanner.plan(kind: .short, handoff: handoff(kind: "short", id: "x", outDir: "/tmp/elsewhere/take-1"),
                                    videoFolder: nil, workspace: workspace, date: date)
        XCTAssertTrue(workspace.isInsideTakes(plan.folder))
        XCTAssertTrue(plan.folder.lastPathComponent.contains("free-take-1"))
    }

    func testDotDotCannotEscapeTakes() {
        let sneaky = workspace.takesRoot.appendingPathComponent("shorts/../../outside")
        XCTAssertFalse(workspace.isInsideTakes(sneaky))
        XCTAssertFalse(workspace.isInsideTakes(workspace.takesRoot))
    }

    func testSymlinkCannotEscapeTakes() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-outside-\(UUID().uuidString)")
        make(outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = workspace.takesRoot.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertFalse(workspace.isInsideTakes(link.appendingPathComponent("take-1")))
    }

    func testFreeShortsNumberUpPerDay() {
        make(workspace.shortsRoot.appendingPathComponent("2026-10-19-free-take-1"))
        make(workspace.shortsRoot.appendingPathComponent("2026-10-19-free-take-2"))
        let plan = TakePlanner.plan(kind: .short, handoff: nil, videoFolder: nil, workspace: workspace, date: date)
        XCTAssertEqual(plan.number, 3)
        XCTAssertEqual(plan.id, "free")
    }

    func testFreeLongTakesGoInAnUntitledFolder() {
        let day = TakePlanner.dayString(date)
        let plan = TakePlanner.plan(kind: .long, handoff: nil, videoFolder: nil, workspace: workspace,
                                    date: date, captureIsScreen: true)
        XCTAssertEqual(plan.folder, workspace.longRoot.appendingPathComponent("untitled-\(day)/take-1", isDirectory: true))
        XCTAssertEqual(plan.mode, .screen)

        make(plan.folder)
        let next = TakePlanner.plan(kind: .long, handoff: nil, videoFolder: plan.folder.deletingLastPathComponent(),
                                    workspace: workspace, date: date)
        XCTAssertEqual(next.number, 2)
    }

    func testVideoFolderOfAnOutDir() {
        let a = URL(fileURLWithPath: "/w/takes/long/my-video/take-3")
        let b = URL(fileURLWithPath: "/w/takes/long/my-video")
        XCTAssertEqual(TakePlanner.videoFolder(of: a).path, "/w/takes/long/my-video")
        XCTAssertEqual(TakePlanner.videoFolder(of: b).path, "/w/takes/long/my-video")
    }

    func testTakeJsonFollowsTheContract() throws {
        let plan = TakePlan(folder: root, number: 2, id: "w42-03", title: "Ship it ugly", kind: .short, mode: .cards)
        let manifest = TakeManifest(
            plan: plan, started: Date(timeIntervalSince1970: 0), durationSeconds: 41.24, fps: 30,
            camera: "take.mov", screen: nil, mic: nil, clicks: nil,
            crop: TakeManifest.Crop(x: 555, y: 0, w: 810, h: 1440, mirrored: false),
            preview: "short.mov"
        )
        try manifest.write(to: root)
        let data = try Data(contentsOf: root.appendingPathComponent("take.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["schema"] as? String, "take/v1")
        XCTAssertEqual(object["id"] as? String, "w42-03")
        XCTAssertEqual(object["kind"] as? String, "short")
        XCTAssertEqual(object["take"] as? Int, 2)
        XCTAssertEqual(object["mode"] as? String, "cards")
        XCTAssertEqual(object["duration_s"] as? Double, 41.2)
        XCTAssertEqual(object["fps"] as? Int, 30)
        XCTAssertTrue(object["clicks"] is NSNull)
        let files = try XCTUnwrap(object["files"] as? [String: Any])
        XCTAssertEqual(files["camera"] as? String, "take.mov")
        XCTAssertTrue(files["screen"] is NSNull)
        let crop = try XCTUnwrap(object["crop"] as? [String: Any])
        XCTAssertEqual(crop["w"] as? Int, 810)
        XCTAssertEqual(crop["mirrored"] as? Bool, false)

        TakeManifest.setFile("mic", "mic.wav", in: root)
        let updated = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("take.json"))) as? [String: Any]
        XCTAssertEqual((updated?["files"] as? [String: Any])?["mic"] as? String, "mic.wav")
    }
}
