import Foundation

/// The two things the recorder takes from the brand: a name for window titles
/// and an accent colour.
struct BrandInfo: Equatable {
    var name: String
    var accentHex: String

    static let fallback = BrandInfo(name: "", accentHex: "#D4AD59")

    /// Window title such as "Northwind Recorder", or "Studio Recorder" without a brand.
    var recorderTitle: String { name.isEmpty ? "Studio Recorder" : "\(name) Recorder" }

    /// Reads `workspace/.brand/brand.resolved.json`, then `<repo>/brand/brand.json`.
    static func load(workspace: Workspace) -> BrandInfo {
        for url in [workspace.brandResolvedURL, workspace.brandSourceURL].compactMap({ $0 }) {
            if let info = parse(url) { return info }
        }
        return fallback
    }

    static func parse(_ url: URL) -> BrandInfo? {
        guard let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let palette = object["palette"] as? [String: Any]
        let accent = (palette?["accent"] as? String).flatMap(normalizedHex) ?? fallback.accentHex
        return BrandInfo(name: name, accentHex: accent)
    }

    /// "#ffd84d" or "FFD84D" becomes "#FFD84D". nil when it is not a 6 digit hex colour.
    static func normalizedHex(_ text: String) -> String? {
        var hex = text.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + hex.uppercased()
    }

    /// Red, green and blue as 0...1.
    var accentRGB: (Double, Double, Double) {
        let hex = String(accentHex.dropFirst())
        let value = UInt32(hex, radix: 16) ?? 0xD4AD59
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }
}
