import Foundation
import CoreGraphics

// MARK: - Reader layout
//
// Foundation-only. The follow view is a scrolling column of
// ALL the script (like a present-mode reader): every box has a fixed, computed
// height, so the view always knows where the line being read is and can pin it just under the
// camera. Line breaks are ours (whole phrases), so row heights are exact, not measured.

struct BoxLayout {
    let index: Int
    /// Top of the box in column coordinates.
    let y: CGFloat
    /// Whole box including the gap after it.
    let height: CGFloat
    /// Word ranges, one per line (spoken boxes). Empty for cards.
    let lines: [Range<Int>]
    /// Space above the first line (gesture tag) or the card's own padding.
    let head: CGFloat
    /// Height of the card itself (action / voiceover), without the trailing gap.
    let cardHeight: CGFloat
}

struct PrompterLayout {

    let boxes: [BoxLayout]
    let totalHeight: CGFloat
    let fontSize: Double
    let lineHeight: CGFloat

    /// Line-height 1.42.
    static let lineHeightFactor: CGFloat = 1.42
    static let cardFontFactor: Double = 0.92
    static let cardPad: CGFloat = 14
    static let columnLeft: CGFloat = 38
    static let columnRight: CGFloat = 22
    /// Space above the reading line inside the window (the camera gap).
    static let topGap: CGFloat = 16

    static func columnWidth(panelWidth: Double) -> Double {
        max(200, panelWidth - Double(columnLeft + columnRight))
    }

    /// Y of the reading line's centre inside the window.
    static func readCentre(fontSize: Double) -> CGFloat {
        topGap + CGFloat(fontSize) * lineHeightFactor / 2
    }

    static func build(boxes: [FollowBox], fontSize: Double, columnWidth: Double) -> PrompterLayout {
        let lh = CGFloat(fontSize) * lineHeightFactor
        let gap = CGFloat(fontSize) * 0.8
        var y: CGFloat = 0
        var out: [BoxLayout] = []
        for (i, box) in boxes.enumerated() {
            switch box.kind {
            case .spoken:
                let starts = box.lineStarts(maxChars: TeleprompterScript.charsPerLine(width: columnWidth, fontSize: fontSize))
                var lines: [Range<Int>] = []
                var from = 0
                for k in 1...max(1, box.words.count) {
                    if k == box.words.count || starts.contains(k) { lines.append(from..<k); from = k }
                }
                let head: CGFloat = box.gesture != nil ? CGFloat(fontSize) * 0.62 : 0
                let h = head + CGFloat(lines.count) * lh + gap
                out.append(BoxLayout(index: i, y: y, height: h, lines: lines, head: head, cardHeight: 0))
                y += h
            case .action, .voiceover:
                let cfs = fontSize * (box.kind == .voiceover ? 0.8 : cardFontFactor)
                let words = box.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                let starts = TeleprompterScript.phraseLineStarts(
                    words, maxChars: TeleprompterScript.charsPerLine(width: columnWidth - 36, fontSize: cfs))
                var n = 1
                for k in 1..<max(1, words.count) where starts.contains(k) { n += 1 }
                let labelH = CGFloat(fontSize) * 0.62
                let card = cardPad * 2 + labelH + CGFloat(n) * CGFloat(cfs) * lineHeightFactor * 0.96
                out.append(BoxLayout(index: i, y: y, height: card + gap, lines: [], head: cardPad, cardHeight: card))
                y += card + gap
            }
        }
        return PrompterLayout(boxes: out, totalHeight: y, fontSize: fontSize, lineHeight: lh)
    }

    /// Centre of the line being read, in column coordinates.
    /// `focus` is the follower's focus box, `wordsRead` the words already said in it.
    func readY(focus: Int, wordsRead: Int) -> CGFloat {
        guard boxes.indices.contains(focus) else { return 0 }
        let b = boxes[focus]
        // A card sits with its top where a line would: the whole card is the thing to read.
        if b.lines.isEmpty { return b.y + lineHeight / 2 }
        let word = min(max(0, wordsRead), (b.lines.last?.upperBound ?? 1) - 1)
        let line = b.lines.firstIndex(where: { $0.contains(word) }) ?? 0
        return b.y + b.head + CGFloat(line) * lineHeight + lineHeight / 2
    }
}

// MARK: - Camera spot

enum CameraSide: String, CaseIterable {
    case under, left, right
    var label: String {
        switch self {
        case .under: return "Under the camera"
        case .left:  return "Left of the camera"
        case .right: return "Right of the camera"
        }
    }
}

enum CameraPlacement {
    /// Where to put the prompter window, in screen coordinates (origin bottom-left).
    /// `spot` is the camera lens in screen coordinates. The window's reading line lands
    /// right under (or beside, level with) the lens.
    static func frame(spot: CGPoint, side: CameraSide, size: CGSize, readCentre: CGFloat,
                      screen: CGRect) -> CGRect {
        var size = size
        var origin = CGPoint.zero
        let near: CGFloat = 30            // distance from lens to the window edge / reading line
        switch side {
        case .under:
            let lineY = spot.y - near      // centre of the reading line
            origin = CGPoint(x: spot.x - size.width / 2, y: lineY + readCentre - size.height)
        case .left:
            size.width = min(size.width, max(420, spot.x - near - screen.minX - 8))
            origin = CGPoint(x: spot.x - near - size.width, y: spot.y + readCentre - size.height)
        case .right:
            size.width = min(size.width, max(420, screen.maxX - spot.x - near - 8))
            origin = CGPoint(x: spot.x + near, y: spot.y + readCentre - size.height)
        }
        origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
        origin.y = max(origin.y, screen.minY + 4)
        return CGRect(origin: origin, size: size)
    }
}

// MARK: - Clicker hold detection

/// Tells a long press from a tap, from the press/release reports of the clicker.
/// A device that never reports a release (some send only the press) can never be "held":
/// `holdSupported` stays false until a release has been seen, so taps are never mistaken.
struct HoldDetector {
    static let holdSeconds: TimeInterval = 0.6
    private(set) var holdSupported = false
    private(set) var downAt: TimeInterval?

    mutating func press(at t: TimeInterval) { downAt = t }

    /// Release: returns the held duration.
    mutating func release(at t: TimeInterval) -> TimeInterval? {
        holdSupported = true
        defer { downAt = nil }
        return downAt.map { t - $0 }
    }

    /// Called by the hold timer. True when the button is still down after the hold time.
    func isHeld(at t: TimeInterval) -> Bool {
        guard holdSupported, let d = downAt else { return false }
        return t - d >= Self.holdSeconds - 0.001
    }
}
