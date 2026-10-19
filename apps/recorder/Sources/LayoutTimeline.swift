import AVFoundation
import CoreGraphics
import Foundation

// Dynamic layout. The face card does not have to sit in one fixed position for
// the whole video: depending on the moment it can change, if it makes the
// viewing better. Screen recordings often move by hand in post between
// split / face / screen+corner-cam / zoomed-screen. Here the same idea is
// decided from the take's own signals, because nobody presses anything while
// recording, and it is deliberately conservative: over-active layout changes
// feel restless, so a change needs a long, clear reason and every state is
// held for a while.
//
// States (StudioLook.swift, `StudioGeometry.layoutFrame`): FACE, SPLIT,
// SCREEN (= the fixed layout), FOCUS. Moves are 0.85s power3.inOut morphs of
// the same two elements; FOCUS rides the zoom's own ramps so it is one move.

/// Whether the Studio layout may change during a take.
enum LayoutMode: String, CaseIterable, Identifiable {
    /// Face intro/outro, split or face while the speaker talks with nothing happening
    /// on screen, focus during a long zoom. The default.
    case dynamic = "Dynamic"
    /// Today's behaviour: one layout for the whole take.
    case fixed = "Fixed"

    var id: String { rawValue }
    static let standard: LayoutMode = .dynamic

    init?(argument: String) {
        switch argument.lowercased() {
        case "dynamic", "auto": self = .dynamic
        case "fixed", "static", "off": self = .fixed
        default: return nil
        }
    }
}

// MARK: - Signals

/// What the take itself says about each moment, read from `screen.mov` without
/// decoding a single video frame: how much the screen changed (the encoder's
/// own P-frame sizes) and whether the speaker is talking (mic level).
struct LayoutSignals {
    /// Screen changing, per `screenStep` seconds. Nil = could not be read.
    var screenActive: [Bool]?
    let screenStep = 0.5
    /// Talking, per `speechStep` seconds. Nil = no usable mic track.
    var talking: [Bool]?
    let speechStep = 0.1

    static let none = LayoutSignals(screenActive: nil, talking: nil)

    func screenChanging(at t: Double) -> Bool {
        guard let bins = screenActive, t >= 0 else { return false }
        let i = Int(t / screenStep)
        return i < bins.count ? bins[i] : false
    }

    /// Share of [a, b] the speaker is talking; nil when there is no speech signal.
    func talkingFraction(_ a: Double, _ b: Double) -> Double? {
        guard let bins = talking, b > a else { return nil }
        let i0 = max(0, Int(a / speechStep)), i1 = min(bins.count, Int(b / speechStep))
        guard i1 > i0 else { return nil }
        return Double(bins[i0..<i1].filter { $0 }.count) / Double(i1 - i0)
    }

    /// Reads both signals from a take's `screen.mov`. The first audio track is
    /// the microphone whenever the mic was recorded (`ScreenRecorder` adds it
    /// first). Costs a few seconds for a long take: the video is only
    /// demuxed, and the audio is decoded at 8 kHz mono.
    static func load(rawURL: URL) async -> LayoutSignals {
        let asset = AVURLAsset(url: rawURL)
        var signals = LayoutSignals.none
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            signals.screenActive = screenActivity(asset: asset, track: track, step: signals.screenStep)
        }
        if let track = try? await asset.loadTracks(withMediaType: .audio).first {
            signals.talking = speech(asset: asset, track: track, step: signals.speechStep)
        }
        return signals
    }

    /// Screen change from compressed frame sizes. A P-frame is tiny when
    /// nothing moved and large when a page scrolls, loads or text streams in.
    /// Bytes per bin are normalised by the median keyframe (one whole
    /// picture), so the threshold means the same at any resolution/codec.
    private static func screenActivity(asset: AVAsset, track: AVAssetTrack, step: Double) -> [Bool]? {
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        var bins: [Double] = []
        var keySizes: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            let count = CMSampleBufferGetNumSamples(sample)
            guard count > 0 else { continue }
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard t.isFinite, t >= 0 else { continue }
            let bytes = Double(CMSampleBufferGetTotalSampleSize(sample))
            var sync = true
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[CFString: Any]], let first = attachments.first,
               let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
                sync = !notSync
            }
            if sync { keySizes.append(bytes); continue }
            let i = Int(t / step)
            if i >= bins.count { bins += [Double](repeating: 0, count: i - bins.count + 1) }
            bins[i] += bytes
        }
        guard reader.status == .completed, !bins.isEmpty else { return nil }
        let key = keySizes.isEmpty ? (bins.max() ?? 1) : keySizes.sorted()[keySizes.count / 2]
        let scores = bins.map { $0 / max(key, 1) }
        // Relative to this take's own quiet level (the 20th percentile is a
        // still screen in any real take), never below an absolute floor.
        let p20 = scores.sorted()[scores.count / 5]
        let threshold = max(0.08, 4 * p20)
        return scores.map { $0 > threshold }
    }

    /// Talking = mic level well above the take's own noise floor.
    private static func speech(asset: AVAsset, track: AVAssetTrack, step: Double) -> [Bool]? {
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let rate = 8000.0
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        let window = Int(rate * step)
        var energy: [Double] = []
        var acc = 0.0, n = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                  let base = pointer else { continue }
            let floats = UnsafeRawPointer(base).bindMemory(to: Float.self, capacity: length / 4)
            for k in 0..<(length / 4) {
                let v = Double(floats[k])
                acc += v * v; n += 1
                if n == window {
                    energy.append(10 * log10(acc / Double(n) + 1e-12))
                    acc = 0; n = 0
                }
            }
        }
        guard energy.count > 20 else { return nil }
        let sorted = energy.sorted()
        let floor = sorted[sorted.count * 15 / 100], loud = sorted[sorted.count * 95 / 100]
        // No real dynamic range = no mic (or a dead one): no speech signal.
        guard loud - floor >= 10 else { return nil }
        let threshold = floor + 0.4 * (loud - floor)
        let raw = energy.map { $0 > threshold }
        // Bridge the gaps between words (±0.3s).
        var talking = raw
        let reach = 3
        for i in raw.indices where raw[i] {
            for j in max(0, i - reach)...min(raw.count - 1, i + reach) { talking[j] = true }
        }
        return talking
    }
}

// MARK: - Timeline

/// When the layout changes, to what, and why.
struct LayoutTimeline {

    /// From `start` the layout is `state`, arriving over `ramp` seconds from
    /// whatever the previous stop was.
    struct Stop {
        let state: LayoutState
        var start: Double
        var ramp: Double
        var reason: String
        /// Which reason wins a clash: 3 intro/outro, 2 focus, 1 quiet screen, 0 screen.
        var priority = 0
    }

    enum Rules {
        /// One morph: long enough to read as a move, short enough not to drag.
        static let morph = 0.85
        /// Any state (SCREEN included) is held at least this long, so it never
        /// ping-pongs. Intro/outro and FOCUS are bounded by their own reasons.
        static let minDwell = 7.0
        /// The take opens on the speaker: at least this long…
        static let introMin = 3.5
        /// …up to this long if nothing happens on screen yet.
        static let introMax = 6.0
        /// Activity in the first second is the recorder starting, not content.
        static let introIgnore = 1.0
        /// The take closes on the speaker for up to this long…
        static let outroMax = 5.0
        /// …if there is room for at least this much.
        static let outroMin = 2.5
        /// The last clicks/keys of a take are the speaker stopping the take.
        static let outroIgnoreTail = 1.5
        /// Nothing on screen for this long while the speaker talks → SPLIT…
        static let splitIdle = 9.0
        /// …this long and mostly talking → FACE.
        static let faceIdle = 15.0
        /// Without a speech signal, FACE needs a much longer quiet stretch.
        static let faceIdleNoSpeech = 22.0
        static let talkingForSplit = 0.35
        static let talkingForFace = 0.6
        /// After the screen goes still, wait this long before moving.
        static let settle = 1.0
        /// Be back on SCREEN this long before activity resumes.
        static let landEarly = 0.3
        /// A zoom held this long gets FOCUS (window grows, card tucks away).
        static let focusMinHold = 6.0
        /// Shorter takes keep the fixed layout.
        static let minTake = 20.0
    }

    let stops: [Stop]
    /// Printed in the report.
    var summary: String = ""

    static let fixed = LayoutTimeline(stops: [])

    var isFixed: Bool { !stops.contains { $0.state != .screen } }

    // MARK: Query

    /// The layout at `time`; nil = fixed layout.
    func blend(at time: Double) -> LayoutBlend? {
        guard !isFixed else { return nil }
        guard let index = stops.lastIndex(where: { $0.start <= time }) else {
            return .settled(stops.first?.state ?? .screen)
        }
        let stop = stops[index]
        if index > 0, stop.ramp > 0, time < stop.start + stop.ramp {
            let p = ZoomTimeline.power3InOut(min(max((time - stop.start) / stop.ramp, 0), 1))
            return LayoutBlend(from: stops[index - 1].state, to: stop.state, t: CGFloat(p))
        }
        return .settled(stop.state)
    }

    /// Whether a take can use the dynamic layout at all.
    static func applies(mode: LayoutMode, layout: ScreenLayout, background: StudioBackground, hasCamera: Bool) -> Bool {
        mode == .dynamic && layout == .studio && background.isLight && hasCamera
    }

    // MARK: Build

    private struct Want {
        let state: LayoutState
        var from: Double
        var to: Double
        let rampIn: Double
        let rampOut: Double
        let reason: String
        /// Higher wins an overlap.
        let priority: Int
    }

    static func build(
        duration: Double,
        clicks: [ClickTracker.Click],
        keys: [Double] = [],
        pointer: PointerPath? = nil,
        zoom: ZoomTimeline,
        signals: LayoutSignals,
        cameraSegments: [ClipSegment] = []
    ) -> LayoutTimeline {
        guard duration >= Rules.minTake else {
            var t = LayoutTimeline.fixed
            t.summary = String(format: "take %.0fs < %.0fs: fixed", duration, Rules.minTake)
            return t
        }

        // 1. Activity at 0.1s: anything happening on screen or by hand.
        let step = 0.1
        let n = Int(duration / step) + 1
        var active = [Bool](repeating: false, count: n)
        func mark(_ a: Double, _ b: Double) {
            let i0 = max(0, Int(a / step)), i1 = min(n - 1, Int(b / step))
            if i1 >= i0 { for i in i0...i1 { active[i] = true } }
        }
        for c in clicks { mark(c.time - 0.5, c.time + 1.5) }
        for k in keys { mark(k - 0.3, k + 1.0) }
        if let pointer {
            var t = max(0, pointer.startTime ?? 0)
            let end = min(duration, pointer.endTime ?? 0)
            while t < end {
                if let p = pointer.position(at: t), let q = pointer.position(at: t + 0.25),
                   hypot(Double(q.x - p.x), Double(q.y - p.y)) > 0.01 {
                    mark(t - 0.2, t + 1.0)
                }
                t += 0.25
            }
        }
        if let screen = signals.screenActive {
            for (i, on) in screen.enumerated() where on {
                mark(Double(i) * signals.screenStep - 0.25, Double(i + 1) * signals.screenStep + 0.5)
            }
        }
        for z in zoom.segments { mark(z.start, z.end) }

        // Activity that is not the recorder starting or stopping.
        let firstActivity = active.indices.first { active[$0] && Double($0) * step >= Rules.introIgnore }
            .map { Double($0) * step } ?? duration
        let lastActivity = active.indices.last { active[$0] && Double($0) * step <= duration - Rules.outroIgnoreTail }
            .map { Double($0) * step } ?? 0

        var wants: [Want] = []

        // 2. Intro: open on the speaker.
        let introEnd = min(max(firstActivity - 0.2, Rules.introMin), Rules.introMax)
        wants.append(Want(
            state: .face, from: 0, to: introEnd, rampIn: 0, rampOut: Rules.morph,
            reason: String(format: "intro (first screen activity %.1fs)", firstActivity), priority: 3
        ))

        // 3. Outro: close on the speaker, if the screen work is done.
        let outroStart = max(duration - Rules.outroMax, lastActivity + 0.5)
        if duration - outroStart >= Rules.outroMin {
            wants.append(Want(
                state: .face, from: outroStart, to: duration + 1, rampIn: Rules.morph, rampOut: 0,
                reason: String(format: "outro (last screen activity %.1fs)", lastActivity), priority: 3
            ))
        }

        // 4. FOCUS: a zoom held long enough to be a real stretch of detail work.
        for z in zoom.segments where z.rampOutStart - z.rampInEnd >= Rules.focusMinHold {
            wants.append(Want(
                state: .focus, from: z.start, to: z.rampOutStart,
                rampIn: z.rampInEnd - z.start, rampOut: z.end - z.rampOutStart,
                reason: String(format: "zoom held %.1fs: %@", z.rampOutStart - z.rampInEnd, z.reason), priority: 2
            ))
        }

        // 5. Quiet screen while the speaker talks → SPLIT, or FACE when it goes on.
        var i = 0
        while i < n {
            guard !active[i] else { i += 1; continue }
            var j = i
            while j < n, !active[j] { j += 1 }
            let a = Double(i) * step, b = Double(j) * step
            i = j
            let length = b - a
            guard length >= Rules.splitIdle else { continue }
            let talk = signals.talkingFraction(a, b)
            let from = a + Rules.settle
            let to = b >= duration ? duration + 1 : b - Rules.landEarly - Rules.morph
            let state: LayoutState
            if let talk {
                if length >= Rules.faceIdle, talk >= Rules.talkingForFace { state = .face }
                else if talk >= Rules.talkingForSplit { state = .split }
                else { continue }   // silent and still: the speaker is waiting on the screen, keep it
            } else {
                state = length >= Rules.faceIdleNoSpeech ? .face : .split
            }
            let why = String(format: "screen still %.1fs", length)
                + (talk.map { String(format: ", talking %.0f%%", $0 * 100) } ?? ", no speech signal")
            wants.append(Want(
                state: state, from: from, to: to, rampIn: Rules.morph, rampOut: Rules.morph,
                reason: why, priority: 1
            ))
        }

        // 6. No camera at that moment → no face-led state there.
        if !cameraSegments.isEmpty {
            wants = wants.filter { w in
                cameraSegments.contains { $0.start <= max(0, w.from) + 0.01 && $0.end >= min(w.to, duration) - 0.01 }
            }
        }

        // 7. Overlaps: the higher priority keeps its span, the other is trimmed.
        wants.sort { $0.from < $1.from }
        var kept: [Want] = []
        for var w in wants {
            var drop = false
            for k in kept.indices where kept[k].to > w.from && kept[k].from < w.to {
                if kept[k].priority >= w.priority {
                    w.from = max(w.from, kept[k].to)
                } else {
                    kept[k].to = min(kept[k].to, w.from)
                }
                if w.to - w.from < 0.5 { drop = true }
            }
            kept = kept.filter { $0.to - $0.from >= 0.5 }
            if !drop { kept.append(w) }
        }
        // A trimmed quiet-screen state that became too short is not worth a move.
        kept = kept.filter { $0.priority > 1 || $0.to - $0.from >= Rules.minDwell }
        kept.sort { $0.from < $1.from }

        // 8. Stops.
        var stops: [Stop] = []
        for w in kept {
            if w.from <= 0 {
                stops.append(Stop(state: w.state, start: 0, ramp: 0, reason: w.reason, priority: w.priority))
            } else {
                if stops.isEmpty { stops.append(Stop(state: .screen, start: 0, ramp: 0, reason: "start")) }
                stops.append(Stop(state: w.state, start: w.from, ramp: w.rampIn, reason: w.reason, priority: w.priority))
            }
            if w.to < duration {
                stops.append(Stop(state: .screen, start: w.to, ramp: w.rampOut, reason: "screen activity"))
            }
        }
        if stops.isEmpty { stops = [Stop(state: .screen, start: 0, ramp: 0, reason: "start")] }

        // 9. Rate limit. A SCREEN too short to settle between two other states:
        //    - neither side is FACE → skip it: one direct move (SPLIT→FOCUS)
        //      instead of out-and-back; the window stays visible throughout;
        //    - FACE on a side → the screen work in that gap must stay visible,
        //      so the lower-priority neighbour gives way: trimmed to leave
        //      SCREEN its minimum dwell, or dropped if that leaves it too short.
        //    Two stops of the same state in a row merge.
        func end(of k: Int) -> Double { k + 1 < stops.count ? stops[k + 1].start : duration }
        var changed = true
        while changed {
            changed = false
            for k in stops.indices.dropFirst().dropLast() where stops[k].state == .screen {
                let hold = stops[k + 1].start - stops[k].start
                guard hold < Rules.minDwell else { continue }
                let a = stops[k - 1], b = stops[k + 1]
                changed = true
                if a.state != .face && b.state != .face {
                    stops.remove(at: k)
                    break
                }
                let need = Rules.minDwell - hold
                let yieldA = a.priority < b.priority
                    || (a.priority == b.priority && end(of: k - 1) - a.start < end(of: k + 1) - b.start)
                if yieldA {
                    // A ends earlier.
                    let newStart = stops[k].start - need
                    if newStart - a.start >= Rules.minDwell { stops[k].start = newStart } else { stops.remove(at: k - 1) }
                } else {
                    // B starts later.
                    let newStart = b.start + need
                    if end(of: k + 1) - newStart >= Rules.minDwell { stops[k + 1].start = newStart } else { stops.remove(at: k + 1) }
                }
                break
            }
            if changed { continue }
            for k in stops.indices.dropFirst() where stops[k].state == stops[k - 1].state {
                stops.remove(at: k)
                changed = true
                break
            }
        }

        var timeline = LayoutTimeline(stops: stops)
        let speech = signals.talking.map { bins in
            String(format: "talking %.0f%%", Double(bins.filter { $0 }.count) / Double(max(bins.count, 1)) * 100)
        } ?? "none"
        let screen = signals.screenActive.map { bins in
            String(format: "changing %.0f%%", Double(bins.filter { $0 }.count) / Double(max(bins.count, 1)) * 100)
        } ?? "none"
        timeline.summary = "signals: speech \(speech), screen \(screen), clicks \(clicks.count), keys \(keys.count)"
            + (pointer == nil ? "" : ", pointer log")
        return timeline
    }

    // MARK: Report

    /// Share of the take in each state (settled or arriving).
    func shares(duration: Double) -> [LayoutState: Double] {
        var out: [LayoutState: Double] = [:]
        guard duration > 0 else { return out }
        for (k, stop) in stops.enumerated() {
            let end = k + 1 < stops.count ? stops[k + 1].start : duration
            out[stop.state, default: 0] += max(0, min(end, duration) - stop.start) / duration
        }
        return out
    }

    /// Human-readable: states, % of time, number of moves, each stop and why.
    func report(duration: Double) -> String {
        let changes = max(0, stops.count - 1)
        let shares = shares(duration: duration)
        let split = LayoutState.allCases.compactMap { s in
            shares[s].map { String(format: "%@ %.0f%%", s.rawValue, $0 * 100) }
        }.joined(separator: " · ")
        var lines = [String(format: "layout: %d move(s) in %.0fs (%.1f/min), ", changes, duration,
                            Double(changes) / max(duration / 60, 0.01)) + (isFixed ? "fixed" : split)]
        if !summary.isEmpty { lines.append("  " + summary) }
        for (k, stop) in stops.enumerated() {
            let end = k + 1 < stops.count ? stops[k + 1].start : duration
            let move = stop.ramp > 0 ? String(format: "%.2fs morph", stop.ramp) : "cut in"
            lines.append(String(format: "  %7.2f-%7.2fs  %-6@ (%@)  %@",
                                stop.start, end, stop.state.rawValue, move, stop.reason))
        }
        return lines.joined(separator: "\n")
    }

    /// `layout-N.json` rows.
    func sidecar(mode: LayoutMode, duration: Double) -> [String: Any] {
        let rows: [[String: Any]] = stops.enumerated().map { k, stop in
            [
                "state": stop.state.rawValue, "start": stop.start, "morph": stop.ramp,
                "end": k + 1 < stops.count ? stops[k + 1].start : duration, "reason": stop.reason
            ]
        }
        return ["mode": mode.rawValue, "signals": summary, "stops": rows]
    }
}
