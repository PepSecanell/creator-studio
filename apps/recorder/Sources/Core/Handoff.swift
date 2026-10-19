import Foundation

/// A request from the Studio app: "record this next" (`handoff/v1`).
///
///     {"schema": "handoff/v1", "kind": "short|long", "id": "w42-03", "title": "...",
///      "mode": "cards|script|screen", "teleprompter": "...", "points": ["..."],
///      "out_dir": "/abs/workspace/takes/shorts/2026-10-19-w42-03-take-1",
///      "created": "2026-10-19T09:00:00Z", "brand": "Northwind"}
///
/// Shorts arrive in `handoff/next_take.json`, long videos in `handoff/next_recording.json`.
struct Handoff: Equatable {
    enum Kind: String { case short, long }
    enum Mode: String { case cards, script, screen }

    static let schemaPrefix = "handoff/"
    /// A handoff older than this is ignored.
    static let maxAge: TimeInterval = 6 * 3600

    let kind: Kind
    let id: String
    let title: String
    let mode: Mode
    /// Text for the teleprompter (script and screen modes).
    let teleprompter: String
    /// Talking points (cards mode), shown one per line.
    let points: [String]
    let outDir: URL?
    let created: String
    let createdAt: Date
    let brand: String

    /// Identifies one request. A new press in the Studio app writes a new `created`.
    var identity: String { "\(id)|\(created)" }

    /// What the teleprompter should show for this request.
    var prompterText: String {
        switch mode {
        case .cards:
            return points.joined(separator: "\n")
        case .script, .screen:
            return teleprompter.isEmpty ? points.joined(separator: "\n") : teleprompter
        }
    }

    var prompterStyle: TeleprompterScript.Style {
        switch mode {
        case .cards:  return .cues
        case .script: return .script
        case .screen: return .mixed
        }
    }

    /// A safe file name piece made from the id ("w42-03" stays as it is).
    var folderComponent: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = id.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
        let trimmed = mapped.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "untitled" : trimmed
    }

    /// nil for broken JSON, a wrong schema, a missing id or a handoff older than 6 hours.
    static func parse(_ data: Data, fileDate: Date? = nil, now: Date = Date()) -> Handoff? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func text(_ key: String) -> String {
            switch object[key] {
            case let s as String: return s
            case let n as NSNumber: return n.stringValue
            default: return ""
            }
        }
        let schema = text("schema")
        guard schema.isEmpty || schema.hasPrefix(schemaPrefix) else { return nil }
        let id = text("id").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, let kind = Kind(rawValue: text("kind").lowercased()) else { return nil }

        let created = text("created")
        guard let createdAt = parseDate(created) ?? fileDate, now.timeIntervalSince(createdAt) < maxAge else {
            return nil
        }
        let points = (object["points"] as? [Any])?.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        let outPath = text("out_dir").trimmingCharacters(in: .whitespacesAndNewlines)
        let outDir = outPath.hasPrefix("/") ? URL(fileURLWithPath: outPath, isDirectory: true) : nil
        let defaultMode: Mode = kind == .long ? .script : .cards
        return Handoff(
            kind: kind, id: id, title: text("title"),
            mode: Mode(rawValue: text("mode").lowercased()) ?? defaultMode,
            teleprompter: text("teleprompter"), points: points, outDir: outDir,
            created: created, createdAt: createdAt, brand: text("brand")
        )
    }

    static func load(from url: URL, now: Date = Date()) -> Handoff? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        return parse(data, fileDate: modified, now: now)
    }

    static func parseDate(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}

/// Decides which new handoff acts when both files changed. Pure.
enum HandoffArbiter {
    /// The newest handoff that has not been used yet. A tie goes to the Short.
    static func pick(_ candidates: [Handoff?], used: Set<String>) -> Handoff? {
        candidates.compactMap { $0 }
            .filter { !used.contains($0.identity) }
            .max { a, b in
                if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
                return a.kind == .long && b.kind == .short
            }
    }
}

/// Remembers which handoffs were already applied, so a relaunch inside the
/// six hour window does not pull the app back to an old request.
struct HandoffLedger {
    private let defaults: UserDefaults
    private let key: String
    private let limit = 40

    init(defaults: UserDefaults = .standard, key: String = "usedHandoffs") {
        self.defaults = defaults
        self.key = key
    }

    var used: Set<String> { Set(defaults.stringArray(forKey: key) ?? []) }

    func markUsed(_ handoff: Handoff) {
        var list = defaults.stringArray(forKey: key) ?? []
        guard !list.contains(handoff.identity) else { return }
        list.append(handoff.identity)
        defaults.set(Array(list.suffix(limit)), forKey: key)
    }
}
