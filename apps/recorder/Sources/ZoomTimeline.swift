import CoreGraphics
import Foundation

/// How the export decides when to push in.
///
/// A zoom on every click is overwhelming: the click-driven policy spent most of
/// a test take zoomed in. A push-in should happen when it is needed, not always. `.smart` is the default now; the old policy
/// survives only as the explicit `.everyClick` option and is never a default.
enum ZoomMode: String, CaseIterable, Identifiable {
    /// Rare, meaningful zooms: sustained work in one small spot, typing,
    /// or a manual hotkey mark. Manual marks always win.
    case smart = "Smart"
    /// Only the "zoom here" / "zoom out" hotkeys.
    case manual = "Manual"
    /// Never zoom.
    case off = "Off"
    /// The old behaviour: every click cluster zooms. Explicit opt-in only.
    case everyClick = "Every click"

    var id: String { rawValue }

    /// Shown in the app. `.everyClick` stays reachable from the re-export CLI
    /// only, so it can never be picked by accident.
    static let pickerCases: [ZoomMode] = [.smart, .manual, .off]

    init?(argument: String) {
        switch argument.lowercased() {
        case "smart": self = .smart
        case "manual", "manual-only": self = .manual
        case "off", "none": self = .off
        case "clicks", "every-click", "everyclick", "legacy": self = .everyClick
        default: return nil
        }
    }
}

/// A hotkey press during the take: "zoom here now" or "back to overview".
struct ZoomMark {
    let time: Double
    let zoomIn: Bool
    /// Pointer position when the key was pressed (capture space, bottom-left).
    let x: Double
    let y: Double
}

/// Everything the Smart policy looks at.
struct ZoomActivity {
    var clicks: [ClickTracker.Click] = []
    /// Keystroke timestamps only, never which key.
    var keys: [Double] = []
    var pointer: PointerPath?
    var marks: [ZoomMark] = []
}

/// Turns what happened during a take into camera moves.
///
/// Smart policy in one paragraph: the camera stays on the overview unless
/// the work is *sustained and small*, three or more distinct clicks inside a
/// small box over at least 2.5s, a burst of typing where you last clicked, or
/// (with a pointer log) the pointer actively circling one detail for 3.5s.
/// Isolated navigation clicks, clicks spread across the screen and scrolling
/// never qualify. Then rate limits: one zoom-in per 11s at most, 2.5s of
/// overview between zooms, nearby candidates merge, a zoom holds at least
/// 2.5s and leaves as soon as the activity leaves its region or goes idle.
/// The zoom level fits the region (1.5 to 2.2x), not the maximum.
struct ZoomTimeline {

    /// One point the camera settles on while zoomed.
    struct Key {
        /// When the camera should have arrived.
        let time: Double
        /// Normalised screen position, origin bottom-left.
        let center: CGPoint
        /// Zoom relative to the screen filling the frame. 1 = full screen.
        let scale: CGFloat
    }

    struct Segment {
        let start: Double
        let rampInEnd: Double
        let rampOutStart: Double
        let end: Double
        let keys: [Key]
        /// Why this zoom exists, saved in zoom.json.
        var reason: String = ""

        /// Where the zoom first settles. Kept for callers that only need one point.
        var center: CGPoint { keys.first?.center ?? CGPoint(x: 0.5, y: 0.5) }
    }

    /// What the camera is doing at one instant.
    struct State {
        /// 0 = overview (no zoom), 1 = fully zoomed. Already eased.
        let progress: CGFloat
        /// Target zoom while zoomed in.
        let scale: CGFloat
        /// Normalised screen focus, origin bottom-left.
        let center: CGPoint

        /// Effective scale for a layout that zooms the full-frame screen
        /// about the focus (the classic look).
        var blendedScale: CGFloat { 1 + (scale - 1) * progress }
    }

    // MARK: Every-click (legacy) constants

    /// Clicks within this many seconds belong to the same moment.
    static let clusterGap: Double = 2.5
    /// Two zooms closer than this merge into one that pans between them.
    static let mergeGap: Double = 1.2
    static let preRoll: Double = 0.85
    static let rampIn: Double = 1.0
    static let hold: Double = 2.0
    static let rampOut: Double = 1.0
    /// A glide between two keys inside one zoom.
    static let panDuration: Double = 0.9
    static let minScale: CGFloat = 1.35
    /// Upper bound for the Amount slider and any per-take override.
    static let scaleCap: CGFloat = 3.0

    // MARK: Smart constants

    enum Smart {
        /// A double-click is one action, not two.
        static let doubleClickGap = 0.45
        static let doubleClickDistance = 0.015
        /// Activity with a longer pause than this is two moments, not one.
        static let continuityGap = 3.0
        /// "Small region": normalised capture units, per axis.
        static let regionWidth = 0.18
        static let regionHeight = 0.22
        /// Sustained = at least this long…
        static let minDwell = 2.5
        /// …with at least this many distinct clicks (typing counts on its own).
        static let minClicks = 3
        /// Keystrokes closer than this are one burst.
        static let typingGap = 1.2
        static let burstMinKeys = 4
        static let burstMinSpan = 0.8
        /// A burst qualifies on its own with this many keys (a word or two).
        static let typingQualifyKeys = 6
        /// Typing is placed where you last clicked, if that was this recent.
        static let typingAnchorWindow = 15.0
        /// Pointer "pointing at a detail": circling inside a tiny box.
        static let hoverBox = (w: 0.10, h: 0.12)
        static let hoverMinDwell = 3.5
        static let hoverMinPath = 0.12
        /// Merge candidates this close in time whose union is still small.
        static let mergeGap = 4.0
        static let mergeWidth = 0.30
        static let mergeHeight = 0.34
        /// Rate limits.
        static let minInterval = 11.0
        static let minRest = 2.5
        /// Timing of one zoom.
        static let arriveAfterStart = 0.25
        static let rampIn = 0.9
        static let minHold = 2.5
        static let tail = 1.2
        static let rampOut = 0.9
        /// Adaptive level.
        static let minScale: CGFloat = 1.5
        static let maxScale: CGFloat = 2.2
        /// Manual "zoom here" level (capped by the Amount setting).
        static let manualScale: CGFloat = 2.0
        /// A manual zoom with no "zoom out" mark holds this long at most.
        static let manualFallbackHold = 8.0
        /// After a manual "zoom out", no automatic zoom starts for this long.
        static let manualQuiet = 4.0
    }

    let segments: [Segment]
    let maxScale: CGFloat

    static let none = ZoomTimeline(segments: [], maxScale: 1)

    // MARK: - Build

    static func build(mode: ZoomMode, activity: ZoomActivity, maxScale requested: CGFloat) -> ZoomTimeline {
        let cap = min(requested, scaleCap)
        guard cap > 1 else { return .none }
        switch mode {
        case .off:
            return .none
        case .everyClick:
            return build(from: activity.clicks, maxScale: cap)
        case .manual:
            return ZoomTimeline(segments: manualSegments(activity, cap: cap), maxScale: cap)
        case .smart:
            let manual = manualSegments(activity, cap: cap)
            let outs = activity.marks.filter { !$0.zoomIn }.map(\.time)
            var auto = smartSegments(activity, cap: cap)

            // Manual marks always win: drop automatic zooms that collide with
            // a manual one, cut any that a "zoom out" lands in, and stay quiet
            // for a moment after a "zoom out".
            auto = auto.filter { seg in
                !manual.contains { seg.start < $0.end + 1 && seg.end > $0.start - 1 }
                    && !outs.contains { seg.start >= $0 && seg.start < $0 + Smart.minRest + Smart.manualQuiet }
            }
            auto = auto.map { seg in
                guard let out = outs.first(where: { $0 > seg.start && $0 < seg.rampOutStart }) else { return seg }
                let rampOutStart = max(seg.start + 0.2, out)
                var cut = Segment(
                    start: seg.start, rampInEnd: min(seg.rampInEnd, rampOutStart),
                    rampOutStart: rampOutStart, end: rampOutStart + Smart.rampOut, keys: seg.keys
                )
                cut.reason = seg.reason + " (cut by manual zoom-out)"
                return cut
            }
            let all = (auto + manual).sorted { $0.start < $1.start }
            return ZoomTimeline(segments: all, maxScale: cap)
        }
    }

    /// The legacy click-driven timeline: every click cluster zooms. Kept for
    /// `.everyClick` and for comparisons.
    static func build(from clicks: [ClickTracker.Click], maxScale requested: CGFloat) -> ZoomTimeline {
        let maxScale = min(requested, scaleCap)
        guard !clicks.isEmpty, maxScale > 1 else { return .none }

        let sorted = clicks.sorted { $0.time < $1.time }

        var clusters: [[ClickTracker.Click]] = []
        var current: [ClickTracker.Click] = [sorted[0]]
        for click in sorted.dropFirst() {
            if click.time - (current.last?.time ?? 0) <= clusterGap {
                current.append(click)
            } else {
                clusters.append(current)
                current = [click]
            }
        }
        clusters.append(current)

        var segments: [Segment] = []
        for cluster in clusters {
            guard let first = cluster.first, let last = cluster.last else { continue }
            let keys = keysFor(cluster, maxScale: maxScale)

            let start = max(0, first.time - preRoll)
            let rampInEnd = start + rampIn
            let rampOutStart = max(rampInEnd, last.time + hold)
            let end = rampOutStart + rampOut

            if let previous = segments.last, start < previous.end + mergeGap {
                segments.removeLast()
                segments.append(Segment(
                    start: previous.start,
                    rampInEnd: previous.rampInEnd,
                    rampOutStart: max(previous.rampOutStart, rampOutStart),
                    end: max(previous.end, end),
                    keys: previous.keys + keys,
                    reason: "clicks"
                ))
            } else {
                segments.append(Segment(
                    start: start, rampInEnd: rampInEnd,
                    rampOutStart: rampOutStart, end: end, keys: keys, reason: "clicks"
                ))
            }
        }

        return ZoomTimeline(segments: segments, maxScale: maxScale)
    }

    private static func keysFor(_ cluster: [ClickTracker.Click], maxScale: CGFloat) -> [Key] {
        let xs = cluster.map(\.x), ys = cluster.map(\.y)
        let minX = xs.min() ?? 0.5, maxX = xs.max() ?? 0.5
        let minY = ys.min() ?? 0.5, maxY = ys.max() ?? 0.5
        let span = CGFloat(max(maxX - minX, maxY - minY))

        let fit = span > 0.001 ? 0.75 / span : maxScale
        let scale = min(maxScale, max(min(minScale, maxScale), fit))

        if span * scale <= 0.75 {
            return [Key(
                time: cluster[0].time,
                center: CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2),
                scale: scale
            )]
        }

        var keys: [Key] = []
        for click in cluster {
            let point = CGPoint(x: click.x, y: click.y)
            if let previous = keys.last {
                let dx = abs(point.x - previous.center.x) * scale
                let dy = abs(point.y - previous.center.y) * scale
                if max(dx, dy) < 0.10 { continue }
            }
            keys.append(Key(time: click.time, center: point, scale: scale))
        }
        return keys
    }

    // MARK: - Smart

    /// One piece of activity: a click (instant) or a typing burst (interval).
    private struct Activity {
        let t0: Double
        let t1: Double
        let x: Double
        let y: Double
        let clicks: Int
        let keys: Int
    }

    /// A stretch of sustained, small-region work.
    private struct Candidate {
        var t0: Double
        var t1: Double
        var box: CGRect
        var clicks: Int
        var keys: Int
        var hover: Bool
        var centers: [(Double, CGPoint)]

        var reason: String {
            var parts: [String] = []
            if clicks > 0 { parts.append("\(clicks) clicks") }
            if keys > 0 { parts.append("typing \(keys) keys") }
            if hover { parts.append("pointing") }
            return parts.joined(separator: " + ")
                + String(format: " in %.2fx%.2f over %.1fs", box.width, box.height, t1 - t0)
        }
    }

    private static func smartSegments(_ activity: ZoomActivity, cap: CGFloat) -> [Segment] {
        let events = smartEvents(activity)
        var candidates = clickCandidates(events, pointer: activity.pointer)
        if let pointer = activity.pointer {
            candidates += hoverCandidates(pointer, events: events)
        }
        candidates.sort { $0.t0 < $1.t0 }

        // Merge neighbours whose union is still a small region.
        var merged: [Candidate] = []
        for c in candidates {
            if var last = merged.last, c.t0 - last.t1 <= Smart.mergeGap {
                let union = last.box.union(c.box)
                if union.width <= Smart.mergeWidth, union.height <= Smart.mergeHeight {
                    last.t1 = max(last.t1, c.t1)
                    last.box = union
                    last.clicks += c.clicks
                    last.keys += c.keys
                    last.hover = last.hover || c.hover
                    last.centers += c.centers
                    merged[merged.count - 1] = last
                    continue
                }
            }
            merged.append(c)
        }

        let hi = min(Smart.maxScale, cap)
        let lo = min(Smart.minScale, hi)

        var segments: [Segment] = []
        var lastActivity: [Double] = []   // t1 of the candidate(s) behind each kept segment
        var lastBox: [CGRect] = []
        for c in merged {
            let rampInEnd = c.t0 + Smart.arriveAfterStart
            let start = max(0, rampInEnd - Smart.rampIn)

            if let previous = segments.last {
                let tooSoon = start < previous.start + Smart.minInterval || start < previous.end + Smart.minRest
                if tooSoon {
                    // Close and compatible: keep the existing zoom a little
                    // longer instead of pumping out and back in.
                    let union = lastBox[lastBox.count - 1].union(c.box)
                    let idle = c.t0 - lastActivity[lastActivity.count - 1]
                    if idle <= Smart.mergeGap * 1.5,
                       union.width <= Smart.mergeWidth, union.height <= Smart.mergeHeight {
                        let scale = previous.keys.first?.scale ?? hi
                        let rampOutStart = holdEnd(
                            after: c.t1, box: union, scale: scale,
                            rampInEnd: previous.rampInEnd, events: events, pointer: activity.pointer
                        )
                        segments[segments.count - 1] = Segment(
                            start: previous.start, rampInEnd: previous.rampInEnd,
                            rampOutStart: max(previous.rampOutStart, rampOutStart),
                            end: max(previous.rampOutStart, rampOutStart) + Smart.rampOut,
                            keys: previous.keys + panKeys(c, scale: scale, after: previous.keys.last),
                            reason: previous.reason + " + " + c.reason
                        )
                        lastActivity[lastActivity.count - 1] = c.t1
                        lastBox[lastBox.count - 1] = union
                    }
                    continue
                }
            }

            // The region plus a margin fills ~45% of the view: a single spot
            // goes to the cap, a wider patch stays nearer 1.5x.
            let fit = 0.45 / max(Double(c.box.width) + 0.10, Double(c.box.height) + 0.10)
            let scale = min(hi, max(lo, CGFloat(fit)))
            let rampOutStart = holdEnd(
                after: c.t1, box: c.box, scale: scale,
                rampInEnd: rampInEnd, events: events, pointer: activity.pointer
            )
            let first = Key(time: c.t0, center: CGPoint(x: c.box.midX, y: c.box.midY), scale: scale)
            segments.append(Segment(
                start: start, rampInEnd: rampInEnd,
                rampOutStart: rampOutStart, end: rampOutStart + Smart.rampOut,
                keys: [first], reason: c.reason
            ))
            lastActivity.append(c.t1)
            lastBox.append(c.box)
        }
        return segments
    }

    /// A pan key toward a merged candidate, if it sits noticeably elsewhere.
    private static func panKeys(_ c: Candidate, scale: CGFloat, after previous: Key?) -> [Key] {
        let center = CGPoint(x: c.box.midX, y: c.box.midY)
        if let previous {
            let d = max(abs(center.x - previous.center.x), abs(center.y - previous.center.y)) * scale
            if d < 0.10 { return [] }
        }
        return [Key(time: c.t0, center: center, scale: scale)]
    }

    /// When the zoom should start leaving: a short tail after the last
    /// activity, earlier if the next click lands outside the zoomed view or
    /// the pointer leaves it, but never before the minimum hold.
    private static func holdEnd(
        after t1: Double, box: CGRect, scale: CGFloat, rampInEnd: Double,
        events: [Activity], pointer: PointerPath?
    ) -> Double {
        let earliest = rampInEnd + Smart.minHold
        var leave = t1 + Smart.tail
        let halfW = 0.5 / Double(scale) * 0.85, halfH = 0.5 / Double(scale) * 0.85
        let view = CGRect(x: Double(box.midX) - halfW, y: Double(box.midY) - halfH, width: halfW * 2, height: halfH * 2)
        if let next = events.first(where: { $0.t0 > t1 + 0.05 }), next.t0 < leave,
           !view.contains(CGPoint(x: next.x, y: next.y)) {
            leave = next.t0 - 0.15
        }
        if let pointer {
            var t = t1
            var outside = 0.0
            while t < leave {
                if let p = pointer.position(at: t), !view.contains(p) {
                    outside += 0.05
                    if outside >= 0.5 { leave = t - 0.5; break }
                } else {
                    outside = 0
                }
                t += 0.05
            }
        }
        return max(earliest, leave)
    }

    /// Clicks (double-clicks folded into one) and typing bursts, in time order.
    private static func smartEvents(_ activity: ZoomActivity) -> [Activity] {
        var events: [Activity] = []
        let clicks = activity.clicks.sorted { $0.time < $1.time }
        var previous: ClickTracker.Click?
        for click in clicks {
            if let p = previous, click.time - p.time <= Smart.doubleClickGap,
               abs(click.x - p.x) <= Smart.doubleClickDistance, abs(click.y - p.y) <= Smart.doubleClickDistance {
                previous = click
                continue
            }
            events.append(Activity(t0: click.time, t1: click.time, x: click.x, y: click.y, clicks: 1, keys: 0))
            previous = click
        }

        // Keystrokes next to a manual mark are the hotkey itself.
        let markTimes = activity.marks.map(\.time)
        let keys = activity.keys.sorted().filter { k in !markTimes.contains { abs($0 - k) < 0.3 } }
        var burst: [Double] = []
        func flush() {
            defer { burst.removeAll() }
            guard burst.count >= Smart.burstMinKeys,
                  let t0 = burst.first, let t1 = burst.last, t1 - t0 >= Smart.burstMinSpan else { return }
            // The caret is where you last clicked; failing that, the pointer.
            let anchor: CGPoint?
            if let click = clicks.last(where: { $0.time <= t0 && t0 - $0.time <= Smart.typingAnchorWindow }) {
                anchor = CGPoint(x: click.x, y: click.y)
            } else {
                anchor = activity.pointer?.position(at: t0)
            }
            guard let a = anchor, a.x >= 0, a.x <= 1, a.y >= 0, a.y <= 1 else { return }
            events.append(Activity(t0: t0, t1: t1, x: Double(a.x), y: Double(a.y), clicks: 0, keys: burst.count))
        }
        for k in keys {
            if let last = burst.last, k - last > Smart.typingGap { flush() }
            burst.append(k)
        }
        flush()
        return events.sorted { $0.t0 < $1.t0 }
    }

    /// Greedy scan for sustained work inside one small box.
    private static func clickCandidates(_ events: [Activity], pointer: PointerPath?) -> [Candidate] {
        var out: [Candidate] = []
        var i = 0
        while i < events.count {
            var j = i
            var box = CGRect(x: events[i].x, y: events[i].y, width: 0, height: 0)
            var end = events[i].t1
            while j + 1 < events.count {
                let next = events[j + 1]
                guard next.t0 - end <= Smart.continuityGap else { break }
                let union = box.union(CGRect(x: next.x, y: next.y, width: 0, height: 0))
                guard union.width <= Smart.regionWidth, union.height <= Smart.regionHeight else { break }
                box = union
                end = max(end, next.t1)
                j += 1
            }
            let slice = events[i...j]
            let clicks = slice.reduce(0) { $0 + $1.clicks }
            let keys = slice.reduce(0) { $0 + $1.keys }
            let span = end - events[i].t0
            var ok = (clicks >= Smart.minClicks && span >= Smart.minDwell)
                || (keys >= Smart.typingQualifyKeys && span >= 1.2)
            // With a pointer log, a pointer sweeping all over the screen
            // between the clicks is navigation, not focused work.
            if ok, let pointer, span > 0 {
                let zone = box.insetBy(dx: -0.08, dy: -0.08)
                var inside = 0, total = 0
                var t = events[i].t0
                while t <= end {
                    if let p = pointer.position(at: t) { total += 1; if zone.contains(p) { inside += 1 } }
                    t += 0.1
                }
                if total > 0, Double(inside) / Double(total) < 0.7 { ok = false }
            }
            if ok {
                out.append(Candidate(
                    t0: events[i].t0, t1: end, box: box, clicks: clicks, keys: keys, hover: false,
                    centers: [(events[i].t0, CGPoint(x: box.midX, y: box.midY))]
                ))
                i = j + 1
            } else {
                i += 1
            }
        }
        return out
    }

    /// The pointer actively circling one small detail (not resting: a still
    /// pointer while talking or scrolling is not attention).
    private static func hoverCandidates(_ pointer: PointerPath, events: [Activity]) -> [Candidate] {
        guard let first = pointer.startTime, let last = pointer.endTime else { return [] }
        let step = 0.1
        var out: [Candidate] = []
        var t = first
        while t < last {
            guard let p0 = pointer.position(at: t) else { break }
            var box = CGRect(x: p0.x, y: p0.y, width: 0, height: 0)
            var path = 0.0
            var prev = p0
            var u = t + step
            while u <= last, let p = pointer.position(at: u) {
                let union = box.union(CGRect(x: p.x, y: p.y, width: 0, height: 0))
                if union.width > Smart.hoverBox.w || union.height > Smart.hoverBox.h { break }
                box = union
                path += hypot(Double(p.x - prev.x), Double(p.y - prev.y))
                prev = p
                u += step
            }
            let span = u - step - t
            // Moving the whole time, not parked and nudged once.
            if span >= Smart.hoverMinDwell, path >= Smart.hoverMinPath, path / span >= 0.02 {
                let clicks = events.filter { $0.t0 >= t && $0.t0 <= u }.reduce(0) { $0 + $1.clicks }
                out.append(Candidate(
                    t0: t, t1: u - step, box: box, clicks: clicks, keys: 0, hover: true,
                    centers: [(t, CGPoint(x: box.midX, y: box.midY))]
                ))
                t = u
            } else {
                t += 0.5
            }
        }
        return out
    }

    // MARK: - Manual

    private static func manualSegments(_ activity: ZoomActivity, cap: CGFloat) -> [Segment] {
        let marks = activity.marks.sorted { $0.time < $1.time }
        let scale = min(Smart.manualScale, cap)
        var segments: [Segment] = []
        var index = 0
        while index < marks.count {
            let mark = marks[index]
            guard mark.zoomIn else { index += 1; continue }

            // Consecutive "zoom here" presses pan inside one zoom.
            var keys = [Key(time: mark.time, center: CGPoint(x: mark.x, y: mark.y), scale: scale)]
            var lastIn = mark.time
            var next = index + 1
            while next < marks.count, marks[next].zoomIn, marks[next].time - lastIn <= 20 {
                keys.append(Key(time: marks[next].time, center: CGPoint(x: marks[next].x, y: marks[next].y), scale: scale))
                lastIn = marks[next].time
                next += 1
            }

            let start = max(0, mark.time - 0.35)
            let rampInEnd = start + Smart.rampIn
            var rampOutStart: Double
            if next < marks.count, !marks[next].zoomIn {
                rampOutStart = max(marks[next].time, start + 0.3)
                next += 1
            } else {
                rampOutStart = lastIn + Smart.manualFallbackHold
                if next < marks.count { rampOutStart = min(rampOutStart, marks[next].time - Smart.minRest) }
                if let pointer = activity.pointer, let focus = keys.last {
                    let half = 0.5 / Double(scale) * 0.9
                    let view = CGRect(x: focus.center.x - half, y: focus.center.y - half, width: half * 2, height: half * 2)
                    var t = lastIn + Smart.minHold
                    while t < rampOutStart {
                        if let p = pointer.position(at: t), !view.contains(p) { rampOutStart = t; break }
                        t += 0.1
                    }
                }
                rampOutStart = max(rampOutStart, rampInEnd + Smart.minHold)
            }
            segments.append(Segment(
                start: start, rampInEnd: min(rampInEnd, rampOutStart),
                rampOutStart: rampOutStart, end: rampOutStart + Smart.rampOut,
                keys: keys, reason: keys.count > 1 ? "manual (\(keys.count) marks)" : "manual"
            ))
            index = next
        }
        return segments
    }

    // MARK: - Query

    /// Scale and focal point at a given moment.
    func state(at time: Double) -> State {
        guard let segment = segments.first(where: { time >= $0.start && time <= $0.end }) else {
            return State(progress: 0, scale: 1, center: CGPoint(x: 0.5, y: 0.5))
        }

        let progress: Double
        if time > segment.rampOutStart {
            progress = 1 - (time - segment.rampOutStart) / max(0.0001, segment.end - segment.rampOutStart)
        } else if time < segment.rampInEnd {
            progress = (time - segment.start) / max(0.0001, segment.rampInEnd - segment.start)
        } else {
            progress = 1
        }

        let (center, scale) = focus(in: segment, at: time)
        return State(
            progress: CGFloat(Self.power3InOut(min(max(progress, 0), 1))),
            scale: scale,
            center: center
        )
    }

    /// Where the camera looks inside a zoom: at the latest key, gliding to
    /// the next one so that it arrives just as that moment happens.
    private func focus(in segment: Segment, at time: Double) -> (CGPoint, CGFloat) {
        let keys = segment.keys
        guard var current = keys.first else { return (CGPoint(x: 0.5, y: 0.5), maxScale) }

        for next in keys.dropFirst() {
            let glideEnd = next.time + 0.12
            let glideStart = max(current.time, glideEnd - Self.panDuration)
            if time >= glideEnd {
                current = next
                continue
            }
            if time > glideStart {
                let t = Self.power3InOut((time - glideStart) / max(0.0001, glideEnd - glideStart))
                let center = CGPoint(
                    x: current.center.x + (next.center.x - current.center.x) * CGFloat(t),
                    y: current.center.y + (next.center.y - current.center.y) * CGFloat(t)
                )
                let scale = current.scale * pow(next.scale / current.scale, CGFloat(t))
                return (center, scale)
            }
            break
        }
        return (current.center, current.scale)
    }

    /// GSAP's `power3.inOut`: cubic ease in, cubic ease out.
    static func power3InOut(_ t: Double) -> Double {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    /// Share of `duration` seconds spent at least half zoomed in.
    func zoomedFraction(duration: Double, step: Double = 0.1) -> Double {
        guard duration > 0 else { return 0 }
        var zoomed = 0, total = 0
        var t = 0.0
        while t < duration {
            if state(at: t).progress > 0.5 { zoomed += 1 }
            total += 1
            t += step
        }
        return Double(zoomed) / Double(max(total, 1))
    }

    /// Human-readable summary: % zoomed, zoom-in count, each window and why.
    func report(duration: Double) -> String {
        var lines = [String(format: "zoomed %.1f%% of %.0fs, %d zoom-in(s)",
                            zoomedFraction(duration: duration) * 100, duration, segments.count)]
        for (n, s) in segments.enumerated() {
            let c = s.center
            lines.append(String(
                format: "  #%d %6.2f-%6.2fs (full %.2f-%.2f) %.2fx at (%.2f,%.2f)  %@",
                n + 1, s.start, s.end, s.rampInEnd, s.rampOutStart,
                s.keys.first?.scale ?? 0, c.x, c.y, s.reason
            ))
        }
        return lines.joined(separator: "\n")
    }
}
