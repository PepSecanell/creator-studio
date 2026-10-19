import Foundation

/// Where one take is written, and what `take.json` says about it (`take/v1`).
///
/// A take folder holds:
///
///     take.mov     camera (Shorts: the full frame the 9:16 crop is cut from)
///     screen.mov   screen capture, screen takes only
///     mic.wav      the microphone on its own
///     clicks.json  click log, screen takes only
///     take.json    this file
struct TakePlan: Equatable {
    let folder: URL
    let number: Int
    let id: String
    let title: String
    let kind: Handoff.Kind
    let mode: Handoff.Mode
}

enum TakePlanner {

    /// Picks the folder for the next take. Pure apart from reading folder names.
    ///
    /// - A handoff with an `out_dir` inside `takes/` wins. If that folder already
    ///   holds a take, the number at its end counts up (`...-take-1` becomes `...-take-2`).
    /// - Otherwise a Short goes to `takes/shorts/<date>-free-take-<n>` and a long
    ///   video to `<video folder>/take-<n>`, where the video folder is the one
    ///   picked in the window or `takes/long/untitled-<date>`.
    static func plan(
        kind: Handoff.Kind,
        handoff: Handoff?,
        videoFolder: URL?,
        workspace: Workspace,
        date: Date = Date(),
        captureIsScreen: Bool = false
    ) -> TakePlan {
        let day = dayString(date)
        let fallbackMode: Handoff.Mode = captureIsScreen ? .screen : .cards

        if let handoff, handoff.kind == kind, let out = handoff.outDir, workspace.isInsideTakes(out) {
            let (folder, number) = freeFolder(for: out)
            return TakePlan(folder: folder, number: number, id: handoff.id, title: handoff.title,
                            kind: kind, mode: handoff.mode)
        }

        switch kind {
        case .short:
            let prefix = "\(day)-free-take-"
            let number = highest(in: workspace.shortsRoot, prefix: prefix) + 1
            let folder = workspace.shortsRoot.appendingPathComponent("\(prefix)\(number)", isDirectory: true)
            return TakePlan(folder: folder, number: number, id: "free", title: "",
                            kind: .short, mode: fallbackMode)
        case .long:
            let parent = videoFolder.flatMap { workspace.isInsideTakes($0) ? $0 : nil }
                ?? workspace.longRoot.appendingPathComponent("untitled-\(day)", isDirectory: true)
            let number = highest(in: parent, prefix: "take-") + 1
            let folder = parent.appendingPathComponent("take-\(number)", isDirectory: true)
            return TakePlan(folder: folder, number: number, id: parent.lastPathComponent, title: "",
                            kind: .long, mode: fallbackMode)
        }
    }

    /// The handoff's folder if it is still empty, otherwise the next free number
    /// next to it. A name without a take number becomes a video folder with `take-<n>` inside.
    static func freeFolder(for requested: URL) -> (URL, Int) {
        let name = requested.lastPathComponent
        if let range = name.range(of: #"take-(\d+)$"#, options: .regularExpression),
           let number = Int(name[range].dropFirst(5)) {
            let prefix = String(name[..<range.lowerBound]) + "take-"
            let parent = requested.deletingLastPathComponent()
            if !isUsed(requested) { return (requested, number) }
            let next = max(number, highest(in: parent, prefix: prefix)) + 1
            return (parent.appendingPathComponent("\(prefix)\(next)", isDirectory: true), next)
        }
        let number = highest(in: requested, prefix: "take-") + 1
        return (requested.appendingPathComponent("take-\(number)", isDirectory: true), number)
    }

    /// The video folder a handoff's `out_dir` belongs to: its parent when it ends in
    /// `take-<n>`, otherwise the folder itself.
    static func videoFolder(of outDir: URL) -> URL {
        outDir.lastPathComponent.range(of: #"take-\d+$"#, options: .regularExpression) != nil
            ? outDir.deletingLastPathComponent() : outDir
    }

    static func isUsed(_ folder: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.contains { $0 == "take.json" || $0 == "take.mov" }
    }

    /// Highest `<prefix><n>` among the folder names in `directory`.
    static func highest(in directory: URL, prefix: String) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name -> Int? in
            guard name.hasPrefix(prefix) else { return nil }
            return Int(name.dropFirst(prefix.count).prefix { $0.isNumber })
        }.max() ?? 0
    }

    static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

/// The contents of `take.json`.
struct TakeManifest {
    struct Crop: Equatable {
        var x: Int, y: Int, w: Int, h: Int
        var mirrored: Bool
    }

    var plan: TakePlan
    var started: Date
    var durationSeconds: Double
    var fps: Int
    var camera: String?
    var screen: String?
    var mic: String?
    var clicks: String?
    var crop: Crop?
    /// The screen take with camera, phone and zoom painted in (screen takes only).
    var composite: String?
    /// The 9:16 cut made from take.mov (Shorts only).
    var preview: String?
    /// "remote-button" when the clicker ended the take.
    var stoppedBy: String?

    func json() -> [String: Any] {
        var files: [String: Any] = [
            "camera": camera.map { $0 as Any } ?? NSNull(),
            "screen": screen.map { $0 as Any } ?? NSNull()
        ]
        if let mic { files["mic"] = mic }
        if let composite { files["composite"] = composite }
        if let preview { files["preview"] = preview }
        var object: [String: Any] = [
            "schema": "take/v1",
            "id": plan.id,
            "kind": plan.kind.rawValue,
            "take": plan.number,
            "mode": plan.mode.rawValue,
            "started": ISO8601DateFormatter().string(from: started),
            "duration_s": (durationSeconds * 10).rounded() / 10,
            "fps": fps,
            "files": files,
            "clicks": clicks.map { $0 as Any } ?? NSNull()
        ]
        if !plan.title.isEmpty { object["title"] = plan.title }
        if let stoppedBy { object["stopped_by"] = stoppedBy }
        if let crop {
            object["crop"] = ["x": crop.x, "y": crop.y, "w": crop.w, "h": crop.h, "mirrored": crop.mirrored]
        } else {
            object["crop"] = NSNull()
        }
        return object
    }

    func write(to folder: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: json(), options: [.prettyPrinted, .sortedKeys])
        try data.write(to: folder.appendingPathComponent("take.json"), options: .atomic)
    }

    /// Adds one entry to `files` in an existing `take.json`, for files that
    /// finish after the take is saved (the composite, the separate mic track).
    static func setFile(_ key: String, _ name: String, in folder: URL) {
        let url = folder.appendingPathComponent("take.json")
        guard let data = try? Data(contentsOf: url),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var files = object["files"] as? [String: Any] else { return }
        files[key] = name
        object["files"] = files
        if let out = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: url, options: .atomic)
        }
    }
}
