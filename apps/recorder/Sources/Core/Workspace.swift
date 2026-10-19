import Foundation

/// Where the recorder finds the shared workspace.
///
/// `./studio setup` writes `~/.config/creator-studio/config.json`:
///
///     {"schema": "cs-config/v1", "repo": "/abs/repo", "workspace": "/abs/repo/workspace"}
///
/// Two environment variables override it: `CREATOR_STUDIO_CONFIG` (path of the
/// config file) and `CREATOR_STUDIO_WORKSPACE` (the workspace folder itself).
struct StudioConfig: Equatable {
    var repo: URL?
    var workspace: URL

    enum ConfigError: Error, Equatable {
        case missing(URL)
        case unreadable(URL)
    }

    static func configURL(environment: [String: String], home: URL) -> URL {
        if let path = environment["CREATOR_STUDIO_CONFIG"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent(".config/creator-studio/config.json")
    }

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Result<StudioConfig, ConfigError> {
        let url = configURL(environment: environment, home: home)
        var repo: URL?
        var workspace: URL?

        if let data = try? Data(contentsOf: url) {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return .failure(.unreadable(url))
            }
            if let path = object["repo"] as? String, !path.isEmpty {
                repo = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            }
            if let path = object["workspace"] as? String, !path.isEmpty {
                workspace = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            }
        }
        if let override = environment["CREATOR_STUDIO_WORKSPACE"], !override.isEmpty {
            workspace = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        if workspace == nil, let repo {
            workspace = repo.appendingPathComponent("workspace", isDirectory: true)
        }
        guard let workspace else { return .failure(.missing(url)) }
        return .success(StudioConfig(repo: repo, workspace: workspace))
    }
}

/// The folders inside the workspace that the recorder reads or writes.
struct Workspace: Equatable {
    let root: URL
    let repo: URL?

    init(config: StudioConfig) {
        self.root = config.workspace.standardizedFileURL
        self.repo = config.repo?.standardizedFileURL
    }

    var handoffDir: URL { root.appendingPathComponent("handoff", isDirectory: true) }
    var nextTakeURL: URL { handoffDir.appendingPathComponent("next_take.json") }
    var nextRecordingURL: URL { handoffDir.appendingPathComponent("next_recording.json") }

    var takesRoot: URL { root.appendingPathComponent("takes", isDirectory: true) }
    var shortsRoot: URL { takesRoot.appendingPathComponent("shorts", isDirectory: true) }
    var longRoot: URL { takesRoot.appendingPathComponent("long", isDirectory: true) }

    var brandResolvedURL: URL {
        root.appendingPathComponent(".brand", isDirectory: true).appendingPathComponent("brand.resolved.json")
    }
    var brandSourceURL: URL? {
        repo?.appendingPathComponent("brand", isDirectory: true).appendingPathComponent("brand.json")
    }

    /// The only place the recorder is allowed to write takes. A handoff can ask
    /// for any `out_dir`; anything outside `takes/` is ignored.
    func isInsideTakes(_ url: URL) -> Bool {
        let base = takesRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let path = Self.resolvedPath(url)
        return path != base && path.hasPrefix(base + "/")
    }

    /// Resolves symlinks on the part of the path that exists, so a link inside
    /// `takes/` cannot lead the recorder out of it.
    private static func resolvedPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            tail.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for part in tail { resolved.appendPathComponent(part) }
        return resolved.standardizedFileURL.path
    }

    /// Existing long video folders, newest first, for the Save to picker.
    func existingLongFolders() -> [URL] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: longRoot.path)) ?? []
        let folders = names.filter { !$0.hasPrefix(".") }.compactMap { name -> (URL, Date)? in
            let url = longRoot.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            let date = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
            return (url, date)
        }
        return folders.sorted { $0.1 > $1.1 }.map(\.0)
    }
}
