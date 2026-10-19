import AppKit
import Foundation

/// The pointer sidecar written next to a take as `cursor-N.json`.
///
/// Exists so the export can draw **our own** cursor (bigger, smoothed, with a
/// soft click effect) instead of the tiny one macOS burns into the capture.
/// The cursor goes back to normal when you are not recording, so the system
/// cursor is never hidden or changed. It is only
/// left out of the capture (`SCStreamConfiguration.showsCursor = false`); on
/// screen you see your normal cursor the whole time.
struct PointerLog: Codable {
    var version = 1
    /// "capture": normalised to the captured 16:9 region, origin bottom-left,
    /// the same space as the video. Clicks of the same take share it.
    var space = "capture"
    var clickSpace = "capture"
    /// false = the system cursor is NOT in screen.mov, so the export must draw one.
    var systemCursorInCapture: Bool
    /// `[t, x, y]` rows. Written only when the pointer moves, plus the resting
    /// position just before each move starts, so linear interpolation between
    /// rows is exact (no slow drift across a still stretch).
    var samples: [[Double]]
    /// `[t, hotX/width, hotY/height, width, code]` whenever the system cursor
    /// image changes. `code` is `CursorShape.rawValue` (0 arrow, 1 I-beam,
    /// 2 pointing hand, -1 other); older rows
    /// have no code and are classified from the hotspot at export.
    var shapes: [[Double]]
    /// Keystroke TIMESTAMPS only (seconds). Never which key, never content:
    /// read from the system's key-down *counter*, which carries no identity.
    /// Optional so older logs still decode.
    var keys: [Double]?
    /// `[t, 1 = zoom here / 0 = zoom out, x, y]` from the hotkeys.
    var zoomMarks: [[Double]]?
    /// `[t, x, y, w, h]` bounds of the frontmost app's front window at 5Hz,
    /// capture space, origin bottom-left. Written when it changes.
    var windows: [[Double]]?

    static func load(from url: URL) -> PointerLog? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PointerLog.self, from: data)
    }

    var marks: [ZoomMark] {
        (zoomMarks ?? []).compactMap { row in
            guard row.count >= 4 else { return nil }
            return ZoomMark(time: row[0], zoomIn: row[1] > 0.5, x: row[2], y: row[3])
        }
    }

    /// Shape changes, classified.
    var shapeKeys: [(time: Double, shape: CursorShape)] {
        shapes.compactMap { row in
            guard row.count >= 4 else { return nil }
            if row.count >= 5, let code = CursorShape(rawValue: Int(row[4])) { return (row[0], code) }
            return (row[0], CursorShape.classify(hotX: row[1], hotY: row[2]))
        }
    }
}

/// The cursor shapes we draw. Anything else is drawn as the arrow.
enum CursorShape: Int {
    case other = -1
    case arrow = 0
    case iBeam = 1
    case hand = 2

    /// macOS hotspots, as a share of the image (measured):
    /// arrow (0.18, 0.13), I-beam (0.52, 0.50), pointing hand (0.41, 0.25).
    static func classify(hotX: Double, hotY: Double) -> CursorShape {
        if hotX < 0.30, hotY < 0.22 { return .arrow }
        if abs(hotX - 0.41) < 0.06, abs(hotY - 0.25) < 0.07 { return .hand }
        if abs(hotX - 0.52) < 0.05, abs(hotY - 0.50) < 0.05 { return .iBeam }
        return .other
    }

    /// Live classification at record time: compare with the system's own
    /// cursors, which also tells the open hand apart from the I-beam.
    static func classify(_ cursor: NSCursor) -> CursorShape {
        func ratio(_ c: NSCursor) -> CGPoint {
            let s = c.image.size
            guard s.width > 0, s.height > 0 else { return .zero }
            return CGPoint(x: c.hotSpot.x / s.width, y: c.hotSpot.y / s.height)
        }
        let r = ratio(cursor)
        let aspect = cursor.image.size.width / max(cursor.image.size.height, 1)
        func near(_ ref: NSCursor) -> Bool {
            let q = ratio(ref)
            let refAspect = ref.image.size.width / max(ref.image.size.height, 1)
            return abs(q.x - r.x) < 0.03 && abs(q.y - r.y) < 0.03 && abs(refAspect - aspect) < 0.08
        }
        if near(.arrow) { return .arrow }
        if near(.iBeam) { return .iBeam }
        if near(.pointingHand) { return .hand }
        return .other
    }
}

/// Polls the pointer at 60Hz during a take. Reads only, needs no permission,
/// hides nothing, changes nothing about the cursor you see.
///
/// Also logs, in the same poll and with no new permission prompt:
/// - keystroke **timestamps** from the system key-down counter
///   (`CGEventSource.counterForEventType`). A counter has no key identity, so
///   nothing typed can ever be recovered from the log. It is not an event tap
///   or a keyboard monitor, which is what would need Input Monitoring;
/// - the frontmost app's front window bounds at 5Hz (`CGWindowListCopyWindowInfo`,
///   bounds only, no titles, no pixels);
/// - the hotkey zoom marks (`addMark`).
final class PointerTracker {

    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var samples: [[Double]] = []
    private var shapes: [[Double]] = []
    private var keys: [Double] = []
    private var marks: [[Double]] = []
    private var windows: [[Double]] = []
    private var lastPoint: CGPoint?
    private var lastPollTime: Double?
    private var stillSinceLastSample = false
    private var lastShape: [Double] = []
    private var lastWindow: [Double] = []
    private var lastKeyCount: UInt32?
    private var tick = 0
    private var clock: RecordingClock?
    private var captureRect: CGRect = .zero

    var sampleCount: Int {
        lock.lock(); defer { lock.unlock() }
        return samples.count
    }

    var markCount: Int {
        lock.lock(); defer { lock.unlock() }
        return marks.count
    }

    /// - Parameter captureRect: the captured region in global screen points.
    func start(clock: RecordingClock, captureRect: CGRect) {
        stop()
        self.clock = clock
        self.captureRect = captureRect
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now(),
            repeating: .nanoseconds(16_666_667),
            leeway: .milliseconds(2)
        )
        timer.setEventHandler { [weak self] in
            self?.poll(clock: clock, captureRect: captureRect)
        }
        timer.resume()
        self.timer = timer
    }

    private func normalised(_ location: CGPoint, in captureRect: CGRect) -> CGPoint {
        CGPoint(
            x: (location.x - captureRect.minX) / captureRect.width,
            y: (location.y - captureRect.minY) / captureRect.height
        )
    }

    private func poll(clock: RecordingClock, captureRect: CGRect) {
        guard captureRect.width > 0, captureRect.height > 0 else { return }

        // Keys: count only, read even while paused so a resume does not dump
        // the paused keystrokes into the take.
        let keyCount = CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown)
        let previousKeyCount = lastKeyCount
        lastKeyCount = keyCount

        // nil before the first frame and while paused.
        guard let time = clock.nowSeconds else { return }

        let point = normalised(NSEvent.mouseLocation, in: captureRect)

        lock.lock()
        defer { lock.unlock() }

        if let previousKeyCount, keyCount > previousKeyCount {
            let pressed = min(Int(keyCount - previousKeyCount), 20)
            for _ in 0..<pressed { keys.append((time * 1000).rounded() / 1000) }
        }

        if let last = lastPoint, abs(last.x - point.x) < 1e-5, abs(last.y - point.y) < 1e-5 {
            stillSinceLastSample = true
        } else {
            // Starting to move after a rest: pin the rest position at the
            // previous poll, so interpolation does not smear it over the rest.
            if stillSinceLastSample, let last = lastPoint, let previous = lastPollTime {
                samples.append([previous, Double(last.x), Double(last.y)])
            }
            samples.append([time, Double(point.x), Double(point.y)])
            lastPoint = point
            stillSinceLastSample = false
        }
        lastPollTime = time

        tick += 1
        // Cursor shape at 10Hz: cheap, and shape changes are slow.
        if tick % 6 == 0, let cursor = NSCursor.currentSystem {
            let size = cursor.image.size
            if size.width > 0, size.height > 0 {
                let row = [
                    (cursor.hotSpot.x / size.width * 100).rounded() / 100,
                    (cursor.hotSpot.y / size.height * 100).rounded() / 100,
                    size.width.rounded(),
                    CGFloat(CursorShape.classify(cursor).rawValue)
                ].map(Double.init)
                if row != lastShape {
                    shapes.append([time] + row)
                    lastShape = row
                }
            }
        }
        // Focused window at 5Hz.
        if tick % 12 == 3, let rect = Self.frontWindowBounds() {
            let n = normalised(CGPoint(x: rect.minX, y: rect.minY), in: captureRect)
            let row = [
                Double(n.x), Double(n.y),
                Double(rect.width / captureRect.width), Double(rect.height / captureRect.height)
            ].map { ($0 * 1000).rounded() / 1000 }
            if row != lastWindow {
                windows.append([time] + row)
                lastWindow = row
            }
        }
    }

    /// Bounds of the frontmost app's front, normal-layer window, in global
    /// Cocoa points (origin bottom-left of the main display). Nil when the
    /// frontmost app is Studio Recorder itself, which is not in the capture.
    static func frontWindowBounds() -> CGRect? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        // The list is front-to-back, so the first match is the front window.
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict),
                  bounds.width > 200, bounds.height > 150 else { continue }
            // Quartz window bounds are top-left origin; Cocoa is bottom-left.
            return CGRect(x: bounds.minX, y: mainHeight - bounds.maxY, width: bounds.width, height: bounds.height)
        }
        return nil
    }

    /// A hotkey mark at the current pointer position. Main thread.
    func addMark(zoomIn: Bool) {
        guard let clock, let time = clock.nowSeconds,
              captureRect.width > 0 else { return }
        let p = normalised(NSEvent.mouseLocation, in: captureRect)
        lock.lock()
        marks.append([
            (time * 1000).rounded() / 1000, zoomIn ? 1 : 0,
            (Double(p.x) * 10_000).rounded() / 10_000, (Double(p.y) * 10_000).rounded() / 10_000
        ])
        lock.unlock()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func reset() {
        lock.lock()
        samples.removeAll()
        shapes.removeAll()
        keys.removeAll()
        marks.removeAll()
        windows.removeAll()
        lastPoint = nil
        lastPollTime = nil
        stillSinceLastSample = false
        lastShape = []
        lastWindow = []
        lastKeyCount = nil
        tick = 0
        lock.unlock()
    }

    func log(systemCursorInCapture: Bool) -> PointerLog {
        lock.lock(); defer { lock.unlock() }
        return PointerLog(
            systemCursorInCapture: systemCursorInCapture,
            samples: samples.map { $0.map { ($0 * 10_000).rounded() / 10_000 } },
            shapes: shapes,
            keys: keys,
            zoomMarks: marks,
            windows: windows
        )
    }

    func save(_ log: PointerLog, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(log) else { return }
        try? data.write(to: url)
    }
}

/// A pointer path ready to draw: resampled on a fixed grid and smoothed.
///
/// The smoothing is a **centred** Gaussian (σ = 45ms). The export knows the
/// future, so it can smooth without the lag a live filter (One-Euro, a spring)
/// always adds: the cursor glides but still lands exactly on each click.
struct PointerPath {
    static let rate: Double = 120
    static let sigma: Double = 0.045

    let start: Double
    let xs: [Double]
    let ys: [Double]
    /// Cursor shape changes, from the log. Empty = always the arrow.
    var shapeKeys: [(time: Double, shape: CursorShape)] = []

    var isEmpty: Bool { xs.isEmpty }
    var startTime: Double? { xs.isEmpty ? nil : start }
    var endTime: Double? { xs.isEmpty ? nil : start + Double(xs.count - 1) / Self.rate }

    /// The shape to draw at `time`.
    func shape(at time: Double) -> CursorShape {
        var current = CursorShape.arrow
        for key in shapeKeys {
            if key.time > time { break }
            current = key.shape
        }
        return current == .other ? .arrow : current
    }

    init?(samples: [[Double]]) {
        let rows = samples
            .filter { $0.count >= 3 && $0[0].isFinite && $0[1].isFinite && $0[2].isFinite }
            .sorted { $0[0] < $1[0] }
        guard let first = rows.first, let last = rows.last else { return nil }

        let step = 1 / Self.rate
        let count = max(Int(((last[0] - first[0]) / step).rounded(.up)) + 1, 1)
        var rawX = [Double](repeating: first[1], count: count)
        var rawY = [Double](repeating: first[2], count: count)

        // Linear resample.
        var j = 0
        for i in 0..<count {
            let t = first[0] + Double(i) * step
            while j + 1 < rows.count, rows[j + 1][0] <= t { j += 1 }
            if j + 1 < rows.count {
                let a = rows[j], b = rows[j + 1]
                let u = b[0] > a[0] ? min(max((t - a[0]) / (b[0] - a[0]), 0), 1) : 1
                rawX[i] = a[1] + (b[1] - a[1]) * u
                rawY[i] = a[2] + (b[2] - a[2]) * u
            } else {
                rawX[i] = rows[j][1]
                rawY[i] = rows[j][2]
            }
        }

        // Centred Gaussian.
        let sigmaSteps = Self.sigma * Self.rate
        let radius = Int((sigmaSteps * 3).rounded(.up))
        let kernel = (-radius...radius).map { exp(-Double($0 * $0) / (2 * sigmaSteps * sigmaSteps)) }
        var outX = rawX, outY = rawY
        for i in 0..<count {
            var sx = 0.0, sy = 0.0, sw = 0.0
            for k in -radius...radius {
                let idx = min(max(i + k, 0), count - 1)
                let w = kernel[k + radius]
                sx += rawX[idx] * w
                sy += rawY[idx] * w
                sw += w
            }
            outX[i] = sx / sw
            outY[i] = sy / sw
        }

        self.start = first[0]
        self.xs = outX
        self.ys = outY
    }

    /// Normalised position (capture space, origin bottom-left) at `time`.
    func position(at time: Double) -> CGPoint? {
        guard !xs.isEmpty else { return nil }
        let f = (time - start) * Self.rate
        if f <= 0 { return CGPoint(x: xs[0], y: ys[0]) }
        let i = Int(f)
        if i >= xs.count - 1 { return CGPoint(x: xs[xs.count - 1], y: ys[ys.count - 1]) }
        let u = f - Double(i)
        return CGPoint(
            x: xs[i] + (xs[i + 1] - xs[i]) * u,
            y: ys[i] + (ys[i + 1] - ys[i]) * u
        )
    }

    /// A stand-in path built from clicks alone: rest on each click, glide to
    /// the next one just before it happens. Only for a take whose pointer log
    /// is missing. It is NOT used over a take that has
    /// the system cursor burned in, that would show two cursors.
    static func fromClicks(_ clicks: [ClickTracker.Click]) -> PointerPath? {
        let sorted = clicks.sorted { $0.time < $1.time }
        guard !sorted.isEmpty else { return nil }
        var rows: [[Double]] = []
        for (index, click) in sorted.enumerated() {
            if index > 0 {
                let previous = sorted[index - 1]
                let glide = min(0.7, max(0.15, (click.time - previous.time) * 0.6))
                let glideStart = max(previous.time + 0.05, click.time - 0.08 - glide)
                // Ease the glide by sampling it.
                for s in 0...12 {
                    let u = Double(s) / 12
                    let e = ZoomTimeline.power3InOut(u)
                    rows.append([
                        glideStart + (click.time - 0.08 - glideStart) * u,
                        previous.x + (click.x - previous.x) * e,
                        previous.y + (click.y - previous.y) * e
                    ])
                }
            }
            rows.append([click.time, click.x, click.y])
        }
        return PointerPath(samples: rows)
    }
}

/// What the Studio overview frames over time when "frame the focused window"
/// is on (plan A8): the front app window when that is cleaner than the whole
/// display, else the whole capture. Built from `PointerLog.windows`.
///
/// "Cleaner" = the window covers 20 to 85% of the capture: a maximised window
/// gains nothing from a crop, and a tiny one (a dialog, a palette) would turn
/// the overview into a zoom. A new target only counts once it has held for
/// `settle` seconds, so dragging a window or flicking through apps never
/// makes the frame chase it; each change eases over `transition` seconds.
struct FocusPath {
    struct Key {
        let time: Double
        /// Capture-normalised, origin bottom-left. `full` = whole capture.
        let rect: CGRect
    }

    static let full = CGRect(x: 0, y: 0, width: 1, height: 1)
    static let settle = 1.0
    static let transition = 0.6
    static let minArea = 0.20
    static let maxArea = 0.85

    let keys: [Key]

    var isTrivial: Bool { keys.allSatisfy { $0.rect == Self.full } }

    init(windows rows: [[Double]]) {
        let targets: [(Double, CGRect)] = rows.compactMap { row in
            guard row.count >= 5 else { return nil }
            let clipped = CGRect(x: row[1], y: row[2], width: row[3], height: row[4]).intersection(Self.full)
            guard !clipped.isNull else { return (row[0], Self.full) }
            let area = Double(clipped.width * clipped.height)
            return (row[0], (Self.minArea...Self.maxArea).contains(area) ? clipped : Self.full)
        }
        var keys = [Key(time: -.infinity, rect: Self.full)]
        for (i, target) in targets.enumerated() {
            guard target.1 != keys[keys.count - 1].rect else { continue }
            let heldUntil = i + 1 < targets.count ? targets[i + 1].0 : .infinity
            guard heldUntil - target.0 >= Self.settle else { continue }
            keys.append(Key(time: target.0, rect: target.1))
        }
        self.keys = keys
    }

    /// Framed region at `time`, eased between targets.
    func rect(at time: Double) -> CGRect {
        guard let index = keys.lastIndex(where: { $0.time <= time }) else { return Self.full }
        let key = keys[index]
        guard index > 0 else { return key.rect }
        let u = (time - key.time) / Self.transition
        guard u < 1 else { return key.rect }
        let from = rect(at: key.time - 1e-6)
        let e = CGFloat(ZoomTimeline.power3InOut(max(u, 0)))
        return CGRect(
            x: from.minX + (key.rect.minX - from.minX) * e,
            y: from.minY + (key.rect.minY - from.minY) * e,
            width: from.width + (key.rect.width - from.width) * e,
            height: from.height + (key.rect.height - from.height) * e
        )
    }
}
