import XCTest

final class ConfigTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ text: String, _ name: String) -> URL {
        let url = dir.appendingPathComponent(name)
        try! text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testMissingConfigAsksForSetup() {
        let result = StudioConfig.load(environment: [:], home: dir)
        XCTAssertEqual(result, .failure(.missing(dir.appendingPathComponent(".config/creator-studio/config.json"))))
    }

    func testReadsRepoAndWorkspace() throws {
        let file = write(#"{"schema":"cs-config/v1","repo":"/r/repo","workspace":"/r/repo/workspace"}"#, "config.json")
        let config = try StudioConfig.load(environment: ["CREATOR_STUDIO_CONFIG": file.path], home: dir).get()
        XCTAssertEqual(config.repo?.path, "/r/repo")
        XCTAssertEqual(config.workspace.path, "/r/repo/workspace")
    }

    func testWorkspaceEnvironmentOverridesTheFile() throws {
        let file = write(#"{"repo":"/r/repo","workspace":"/r/repo/workspace"}"#, "config.json")
        let config = try StudioConfig.load(environment: [
            "CREATOR_STUDIO_CONFIG": file.path, "CREATOR_STUDIO_WORKSPACE": "/other/ws"
        ], home: dir).get()
        XCTAssertEqual(config.workspace.path, "/other/ws")
    }

    func testWorkspaceEnvironmentWorksWithoutAConfigFile() throws {
        let config = try StudioConfig.load(environment: ["CREATOR_STUDIO_WORKSPACE": "/ws"], home: dir).get()
        XCTAssertEqual(config.workspace.path, "/ws")
    }

    func testBrokenConfigIsReported() {
        let file = write("nope", "config.json")
        let result = StudioConfig.load(environment: ["CREATOR_STUDIO_CONFIG": file.path], home: dir)
        XCTAssertEqual(result, .failure(.unreadable(file)))
    }

    func testBrandNameAndAccent() throws {
        let file = write(##"{"name":"Northwind","palette":{"accent":"#ffd84d"}}"##, "brand.resolved.json")
        let brand = try XCTUnwrap(BrandInfo.parse(file))
        XCTAssertEqual(brand.name, "Northwind")
        XCTAssertEqual(brand.accentHex, "#FFD84D")
        XCTAssertEqual(brand.recorderTitle, "Northwind Recorder")
        XCTAssertEqual(BrandInfo.fallback.recorderTitle, "Studio Recorder")
    }

    func testBadAccentFallsBack() throws {
        let file = write(#"{"name":"X","palette":{"accent":"yellow"}}"#, "brand.json")
        XCTAssertEqual(try XCTUnwrap(BrandInfo.parse(file)).accentHex, BrandInfo.fallback.accentHex)
    }

    func testBrandFallsBackToTheRepoFile() throws {
        let repo = dir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("brand"), withIntermediateDirectories: true)
        try ##"{"name":"Fromrepo","palette":{"accent":"#112233"}}"##
            .write(to: repo.appendingPathComponent("brand/brand.json"), atomically: true, encoding: .utf8)
        let workspace = Workspace(config: StudioConfig(repo: repo, workspace: dir.appendingPathComponent("ws")))
        XCTAssertEqual(BrandInfo.load(workspace: workspace).name, "Fromrepo")
    }
}
