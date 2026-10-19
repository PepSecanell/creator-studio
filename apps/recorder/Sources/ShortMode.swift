import AVFoundation
import CoreGraphics
import Foundation

// Short mode: native vertical takes for short-form video.
//
// You record exactly like a Just me take: for example an iPhone on the MacBook
// (Continuity Camera, a 4:3 1920x1440 landscape feed), reading from the
// teleprompter. The take is cut to a FIXED 9:16 window: the crop never
// moves, before, during or after the take (moving reframes look
// restless). Where that window sits is
// the only choice, made before Record by dragging it in the preview, and
// remembered between sessions.
//
// Pure geometry + format choice, no AppKit, so tests
// can build the exact same crop the app does.

enum ShortFraming {

    /// The finished file: 1080x1920, 30 fps.
    static let outputSize = CGSize(width: 1080, height: 1920)
    static let frameRate: Int32 = 30
    /// width / height of the finished frame.
    static let aspect: CGFloat = 9.0 / 16.0

    /// Where the crop sits inside its travel, per axis: 0 = far left / top,
    /// 1 = far right / bottom, 0.5 = centred. A fraction rather than pixels,
    /// so a saved position still means the same thing if the feed size
    /// changes (1920x1440 today, 1920x1080 or a portrait feed tomorrow).
    struct Position: Codable, Equatable {
        var x: Double
        var y: Double

        static let centred = Position(x: 0.5, y: 0.5)

        var clamped: Position {
            Position(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
        }
    }

    /// The largest 9:16 window that fits in `frame`, placed at `position`.
    /// Pixels, top-left origin, whole pixels, even width and height (H.264
    /// chroma), never outside the frame.
    ///
    /// 1920x1440 → 810x1440 (x 555 when centred); 1920x1080 → 608x1080;
    /// a portrait 1080x1920 → the whole frame (nothing to crop);
    /// a portrait 1440x1920 → 1080x1920 with 360 px of sideways travel.
    static func cropRect(frame: CGSize, position: Position) -> CGRect {
        guard frame.width >= 2, frame.height >= 2 else { return .zero }
        var h = frame.height
        var w = h * aspect
        if w > frame.width {
            w = frame.width
            h = w / aspect
        }
        w = min(evenRound(w), evenFloor(frame.width))
        h = min(evenRound(h), evenFloor(frame.height))
        let p = position.clamped
        let x = ((frame.width - w) * CGFloat(p.x)).rounded()
        let y = ((frame.height - h) * CGFloat(p.y)).rounded()
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Pixels the crop can move along each axis. Zero on an axis means the
    /// crop already spans the frame there (a landscape feed has no vertical
    /// room at all: the crop uses the full height).
    static func travel(frame: CGSize) -> CGSize {
        let crop = cropRect(frame: frame, position: .centred)
        return CGSize(width: max(0, frame.width - crop.width), height: max(0, frame.height - crop.height))
    }

    static func isPortrait(_ frame: CGSize) -> Bool { frame.height > frame.width }

    /// True when the feed already is 9:16: the take is used whole.
    static func isWholeFrame(_ frame: CGSize) -> Bool {
        let t = travel(frame: frame)
        return t.width < 2 && t.height < 2
    }

    /// How much the crop is scaled to reach 1080x1920 (>1 = upscaled).
    static func scale(frame: CGSize) -> CGFloat {
        let crop = cropRect(frame: frame, position: .centred)
        return crop.height > 0 ? outputSize.height / crop.height : 1
    }

    /// One line for the UI, e.g. "810×1440 of the 1920×1440 feed → 1080×1920 (×1.33)".
    static func describe(frame: CGSize) -> String {
        guard frame.width >= 2, frame.height >= 2 else { return "Waiting for the camera…" }
        let crop = cropRect(frame: frame, position: .centred)
        let feed = "\(Int(frame.width))×\(Int(frame.height))"
        let s = scale(frame: frame)
        let scaleText = abs(s - 1) < 0.005 ? "no scaling" : String(format: "×%.2f", s)
        if isWholeFrame(frame) {
            return "Portrait \(feed) feed, used whole, no crop → 1080×1920 (\(scaleText))"
        }
        let kind = isPortrait(frame) ? "portrait " : ""
        return "\(Int(crop.width))×\(Int(crop.height)) of the \(kind)\(feed) feed → 1080×1920 (\(scaleText))"
    }

    private static func evenRound(_ v: CGFloat) -> CGFloat { max(2, (v / 2).rounded() * 2) }
    private static func evenFloor(_ v: CGFloat) -> CGFloat { max(2, (v / 2).rounded(.down) * 2) }

    // MARK: - Safe zones

    /// Faint guides over the 9:16 frame, in finished-frame pixels (1080x1920,
    /// top-left). Where short-form apps draw their own UI over the video.
    struct SafeZone {
        enum Kind { case keepClear, captions }
        let name: String
        let rect: CGRect
        let kind: Kind
    }

    static let safeZones: [SafeZone] = [
        SafeZone(name: "top bar", rect: CGRect(x: 0, y: 0, width: 1080, height: 290), kind: .keepClear),
        SafeZone(name: "buttons", rect: CGRect(x: 880, y: 290, width: 200, height: 1050), kind: .keepClear),
        SafeZone(name: "captions", rect: CGRect(x: 0, y: 1200, width: 880, height: 140), kind: .captions),
        SafeZone(name: "caption + sound", rect: CGRect(x: 0, y: 1340, width: 1080, height: 580), kind: .keepClear),
    ]

    // MARK: - Length targets

    /// Short-form length targets for the take timer: amber from 40 s, red from 60 s.
    enum LengthBand { case normal, amber, red }

    static func lengthBand(_ seconds: TimeInterval) -> LengthBand {
        if seconds >= 60 { return .red }
        if seconds >= 40 { return .amber }
        return .normal
    }

    // MARK: - Camera format

    /// Short takes want the TALLEST landscape frame: the 9:16 crop spans the
    /// full height, so height is resolution. With an iPhone that is
    /// 1920x1440 (810x1440 crop) instead of the 1920x1080 a Just me take gets
    /// by default (608x1080 crop). Width capped at 1920 like the rest of the
    /// app; landscape formats only, because a portrait-shaped format on a
    /// landscape-mounted phone is untested. Pinned to 30 fps, the output is
    /// 30 fps, and a 30 fps capture gets twice the exposure time per frame.
    ///
    /// Call after the camera input is in the session (setting activeFormat
    /// switches the session to input priority). Best-effort: a camera that
    /// refuses keeps its format. Returns the chosen size.
    @discardableResult
    static func selectFormat(on device: AVCaptureDevice, maxHeight: Int? = nil) -> CGSize? {
        func maxRate(_ f: AVCaptureDevice.Format) -> Double {
            f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        }
        func minRate(_ f: AVCaptureDevice.Format) -> Double {
            f.videoSupportedFrameRateRanges.map(\.minFrameRate).min() ?? 0
        }
        let candidates = device.formats.filter { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return d.width >= d.height && d.width <= 1920
                && Int(d.height) <= (maxHeight ?? Int.max)
                && maxRate(f) >= Double(frameRate) - 0.5 && minRate(f) <= Double(frameRate) + 0.5
        }
        func key(_ f: AVCaptureDevice.Format) -> (Int32, Int32) {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return (d.height, d.width)
        }
        guard let best = candidates.max(by: { key($0) < key($1) }) else { return nil }
        guard (try? device.lockForConfiguration()) != nil else { return nil }
        defer { device.unlockForConfiguration() }
        if best != device.activeFormat {
            device.activeFormat = best
        }
        let duration = CMTime(value: 1, timescale: frameRate)
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        let d = CMVideoFormatDescriptionGetDimensions(best.formatDescription)
        return CGSize(width: Int(d.width), height: Int(d.height))
    }
}
