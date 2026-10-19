import CoreGraphics
import CoreImage
import Foundation
import Vision

// The framing assistant's brain: with a phone as the camera you cannot see how
// you look, whether the shot is too narrow or too wide. Pure
// CoreImage + Vision, no AppKit, so it can run outside the app with the same hint rules.
//
// Coordinates: everything here is NORMALISED CAMERA SPACE with the origin at
// the TOP-LEFT (u right, v down, 0…1 over the recorded camera frame, which is
// already mirrored when "Mirror me" is on, the same pixels as the file).
//
// Nothing drawn or computed here ever reaches a recording: the analysis reads
// a copy of the newest frame (`CameraFrameTap`), and the file is written from
// the device's own sample buffers.

// MARK: - Crops: every way the camera can appear in the finished video

/// One place you can appear, for the current settings.
enum FramingCropSpec: Hashable {
    /// "Just me" → Full: the whole camera frame, as recorded.
    case fullFrame
    /// "Just me" Circle/Rounded, or the Classic screen bubble: an aspect-fill
    /// centred square cut to the shape (`CameraOnlyExport.fill`,
    /// `StudioCompositor.fit(.fill)`).
    case shape(BubbleShape)
    /// Studio face card in one layout state. `.screen` is the fixed card
    /// (tall-left / bottom-right); FACE / SPLIT / FOCUS are the Dynamic
    /// layout's other cards. Crop = `FaceCardFraming`, the one definition.
    case studio(face: FaceLayout, background: StudioBackground, state: LayoutState)
    /// Short mode's fixed 9:16 window, always read CENTRED
    /// (`ShortFraming.cropRect(frame:position:.centred)`) rather than at
    /// wherever `shortPosition` is dragged: an editor that re-crops from
    /// take.mov with its own face tracking never reads the dragged position, so a
    /// centred reference is what actually matches the finished Short. Using
    /// a fixed spec (no associated value) also means dragging the frame
    /// before Record does not reset the coach's hysteresis on every tick.
    case short

    /// Short tab label.
    var name: String {
        switch self {
        case .fullFrame: return "Full frame"
        case .shape(let shape): return shape == .circle ? "Circle" : "Rounded"
        case .studio(_, _, let state):
            switch state {
            case .face: return "Face"
            case .split: return "Side"
            case .screen: return "Card"
            case .focus: return "Corner"
            }
        case .short: return "Short frame"
        }
    }

    /// One line on what this crop is, for the window.
    var caption: String {
        switch self {
        case .fullFrame: return "The whole camera image, exactly the file."
        case .shape(let shape): return "Centred square cut to a \(shape == .circle ? "circle" : "rounded square")."
        case .studio(let face, _, let state):
            switch state {
            case .face: return "You large, intro, outro and long talking bits."
            case .split: return "Big card beside the screen while you talk about it."
            case .screen: return face == .tallLeft ? "The tall card on the left, most of the video." : "The card bottom-right, most of the video."
            case .focus: return "Small card in the corner during a long zoom."
            }
        case .short: return "Roughly where the editor's face-tracked crop will land, not the draggable frame."
        }
    }

    /// Resolves the crop for a camera frame of `cameraSize` pixels.
    func resolve(cameraSize: CGSize) -> ResolvedFramingCrop? {
        guard cameraSize.width > 0, cameraSize.height > 0 else { return nil }
        switch self {
        case .fullFrame:
            let aspect = cameraSize.width / cameraSize.height
            return ResolvedFramingCrop(
                spec: self, region: CGRect(x: 0, y: 0, width: 1, height: 1), aspect: aspect,
                mask: .rect, target: .fullFrame
            )
        case .shape(let shape):
            // Aspect-fill a square, centred, the same geometry as the export.
            let w = cameraSize.width, h = cameraSize.height
            let side = min(w, h)
            let region = CGRect(x: (w - side) / 2 / w, y: (h - side) / 2 / h, width: side / w, height: side / h)
            return ResolvedFramingCrop(
                spec: self, region: region, aspect: 1,
                mask: shape == .circle ? .ellipse : .rounded(radius: shape.cornerRadius(for: 1)),
                target: .square
            )
        case .studio(let face, let background, let state):
            let ref = FaceCardFraming.referenceSize
            let geometry = StudioGeometry(size: ref, screenAspect: 16.0 / 9.0, face: face, background: background)
            let frame = geometry.layoutFrame(state)
            guard let framing = FaceCardFraming(
                cardRect: frame.cardRect, cardRadius: frame.cardRadius, frameSize: ref, cameraSize: cameraSize
            ) else { return nil }
            let vis = framing.visibleRect, cam = framing.cameraRect
            // Output pixels (bottom-left) → normalised camera space (top-left).
            let region = CGRect(
                x: (vis.minX - cam.minX) / cam.width,
                y: (cam.maxY - vis.maxY) / cam.height,
                width: vis.width / cam.width,
                height: vis.height / cam.height
            )
            // The card outline in display units (display height = 1, top-left).
            // The dark tall-left card runs off the frame, so its left corners
            // fall outside the display and only the right ones show.
            let card = CGRect(
                x: (frame.cardRect.minX - vis.minX) / vis.height,
                y: (vis.maxY - frame.cardRect.maxY) / vis.height,
                width: frame.cardRect.width / vis.height,
                height: frame.cardRect.height / vis.height
            )
            let aspect = vis.width / max(vis.height, 1)
            return ResolvedFramingCrop(
                spec: self, region: region, aspect: aspect,
                mask: .card(card, radius: frame.cardRadius / vis.height),
                target: aspect < 0.8 ? .portraitCard : (aspect > 1.4 ? .faceCard : .card)
            )
        case .short:
            let crop = ShortFraming.cropRect(frame: cameraSize, position: .centred)
            guard crop.width >= 2, crop.height >= 2 else { return nil }
            let region = CGRect(
                x: crop.minX / cameraSize.width, y: crop.minY / cameraSize.height,
                width: crop.width / cameraSize.width, height: crop.height / cameraSize.height
            )
            return ResolvedFramingCrop(spec: self, region: region, aspect: ShortFraming.aspect, mask: .rect, target: .short)
        }
    }

    /// Everything you can appear as for one set of recording settings.
    /// `dynamic` = `LayoutTimeline.applies(…)` is true for this take.
    static func studioCrops(face: FaceLayout, background: StudioBackground, dynamic: Bool) -> [FramingCropSpec] {
        let states: [LayoutState] = dynamic ? [.screen, .split, .face, .focus] : [.screen]
        return states.map { .studio(face: face, background: background, state: $0) }
    }
}

/// Where the recommended framing sits inside one crop. Fractions of the
/// crop's height (vertical) or width (horizontal), top-left origin.
struct FramingTarget: Equatable {
    /// Where the eyes should be: the upper-third line, with some give.
    var eyeBand: ClosedRange<CGFloat>
    /// Vision's face box (forehead to just under the chin) ÷ crop height.
    /// A comfortable medium close-up measures 0.30 to 0.33, which is too tight for
    /// hands to show, so Just me → Full aims for 0.17 to 0.25.
    var faceHeight: ClosedRange<CGFloat>
    /// How far the face centre may sit from the middle, × crop width.
    var centreTolerance: CGFloat
    /// Where the top of the head should land (drawn as the headroom zone).
    var headTop: ClosedRange<CGFloat>

    /// Just me → Full: the 16:9 long-form talking head.
    // Wider shot so hand gestures show: a face box at ~1/3 of the frame height leaves the hands out of
    // frame, while ~20% shows chest, desk edge and hands. The older, tighter target lives on as
    // `faceCard`. Eyes on the upper third; with the head top ~0.8 of
    // a face box above the eye line, a 0.17-0.25 face puts the head top at roughly 0.10-0.22.
    static let fullFrame = FramingTarget(eyeBand: 0.29...0.38, faceHeight: 0.17...0.25, centreTolerance: 0.10, headTop: 0.10...0.22)
    /// The Studio FACE card (Screen mode, Dynamic layout): a near-full-frame card for the intro and
    /// outro. The earlier `fullFrame` numbers, so Screen mode coaches
    /// exactly as before and doesn't fight its own Card/Side targets.
    static let faceCard = FramingTarget(eyeBand: 0.28...0.41, faceHeight: 0.26...0.40, centreTolerance: 0.10, headTop: 0.03...0.16)
    /// Bottom-right card, SPLIT card, bottom-right corner card (roughly square).
    static let card = FramingTarget(eyeBand: 0.28...0.41, faceHeight: 0.27...0.44, centreTolerance: 0.12, headTop: 0.03...0.15)
    /// Tall-left card and its corner card: narrow, so centring is what matters.
    static let portraitCard = FramingTarget(eyeBand: 0.28...0.41, faceHeight: 0.28...0.46, centreTolerance: 0.14, headTop: 0.03...0.15)
    /// Circle / rounded square: the face fills more, eyes a touch lower.
    static let square = FramingTarget(eyeBand: 0.32...0.45, faceHeight: 0.32...0.50, centreTolerance: 0.08, headTop: 0.04...0.16)
    /// Short mode, calibrated to the editor's own
    /// `native_framing()` constants, not guessed: NATIVE_EYES = 0.40 (eyes
    /// on that line unless the real chin would reach the caption band) and
    /// NATIVE_FACE_H = 580 px of the 1920-tall output (580/1920 ≈ 0.302).
    /// A tighter band than the Studio cards on purpose. Short has exactly
    /// one target, not several layout states to satisfy at once. The eye
    /// line's ceiling sits close to 0.40 (eyes lower than that pushes the
    /// chin toward the caption band); its floor is looser, since a smaller
    /// eyeY just means more headroom, which the builder crops out anyway.
    // Wider shot: face box 18-28% of the frame (was 25-36%), more room above the head. A landscape iPhone feed cannot get below ~28% (the 9:16 window is only 30%
    // of its width), so the hint also says to turn the iPhone upright: a portrait feed shows ~33% more height.
    static let short = FramingTarget(eyeBand: 0.33...0.41, faceHeight: 0.18...0.28, centreTolerance: 0.12, headTop: 0.10...0.27)
}

/// A crop resolved against a real camera size.
struct ResolvedFramingCrop: Equatable {
    enum Mask: Equatable {
        case rect
        case ellipse
        /// Rounded square, radius as a fraction of the side.
        case rounded(radius: CGFloat)
        /// A Studio card: its rect and radius in display units (height 1,
        /// top-left). May run past the display (the dark tall-left card).
        case card(CGRect, radius: CGFloat)
    }

    let spec: FramingCropSpec
    /// The recorded part of the camera frame, normalised, top-left.
    let region: CGRect
    /// Display width ÷ height.
    let aspect: CGFloat
    let mask: Mask
    let target: FramingTarget

    var name: String { spec.name }

    /// The crop outline for a display drawn in `rect` (top-left coordinates).
    func maskPath(in rect: CGRect) -> CGPath {
        switch mask {
        case .rect:
            return CGPath(rect: rect, transform: nil)
        case .ellipse:
            return CGPath(ellipseIn: rect, transform: nil)
        case .rounded(let radius):
            let r = radius * min(rect.width, rect.height)
            return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        case .card(let card, let radius):
            let k = rect.height
            let placed = CGRect(x: rect.minX + card.minX * k, y: rect.minY + card.minY * k,
                                width: card.width * k, height: card.height * k)
            let r = min(radius * k, placed.width / 2, placed.height / 2)
            return CGPath(roundedRect: placed, cornerWidth: r, cornerHeight: r, transform: nil)
        }
    }

    /// Camera point (normalised, top-left) → crop point (0…1, top-left).
    func toCrop(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - region.minX) / region.width, y: (p.y - region.minY) / region.height)
    }

    func toCrop(_ r: CGRect) -> CGRect {
        let a = toCrop(CGPoint(x: r.minX, y: r.minY))
        return CGRect(x: a.x, y: a.y, width: r.width / region.width, height: r.height / region.height)
    }
}

// MARK: - One frame's measurement

/// The biggest face in a frame, in normalised camera space (top-left).
struct FaceMeasurement: Equatable {
    /// Vision's face box: roughly brow line to chin, cheek to cheek.
    var face: CGRect
    /// Eye centres, image-left first. nil when landmarks were not found.
    var eyes: (CGPoint, CGPoint)?
    /// Camera roll from the eye line, degrees (positive = right eye lower).
    var rollDegrees: CGFloat
    /// Vision's head pose, degrees, when it gave one.
    var pitchDegrees: CGFloat?
    var yawDegrees: CGFloat?

    static func == (a: FaceMeasurement, b: FaceMeasurement) -> Bool {
        a.face == b.face && a.rollDegrees == b.rollDegrees
            && a.eyes?.0 == b.eyes?.0 && a.eyes?.1 == b.eyes?.1
    }

    /// The eye line. Falls back to Vision's typical eye height in its box.
    var eyeY: CGFloat {
        if let eyes { return (eyes.0.y + eyes.1.y) / 2 }
        return face.minY + 0.33 * face.height
    }

    /// Top of the hair: Vision's box starts at the forehead; hair ends
    /// 0.35 to 0.5 of a box higher (measured on sample takes).
    static let headTopFactor: CGFloat = 0.40
    var headTop: CGFloat { face.minY - Self.headTopFactor * face.height }

    /// Where the skin is: the middle of the box, cheeks and nose.
    var skinRect: CGRect {
        CGRect(x: face.minX + 0.22 * face.width, y: face.minY + 0.30 * face.height,
               width: 0.56 * face.width, height: 0.55 * face.height)
    }

    /// Head, shoulders and chest: everything that is not background.
    var personRect: CGRect {
        let top = headTop - 0.05 * face.height
        return CGRect(x: face.midX - 1.7 * face.width, y: top, width: 3.4 * face.width, height: 10)
    }
}

/// A coarse luma grid of the frame (gamma-encoded sRGB, Rec.709 weights, 0…1,
/// row 0 at the top): cheap enough to keep, fine enough to compare the face
/// with the room behind it inside any crop.
struct LumaMap: Equatable {
    let width: Int
    let height: Int
    let values: [Float]

    struct Stats { var mean: Float; var p90: Float; var count: Int }

    /// Cells whose centre is inside `rect` and outside `excluding`.
    func stats(in rect: CGRect, excluding: CGRect? = nil) -> Stats {
        var picked: [Float] = []
        picked.reserveCapacity(width * height / 2)
        for row in 0..<height {
            let v = (CGFloat(row) + 0.5) / CGFloat(height)
            guard v >= rect.minY, v <= rect.maxY else { continue }
            for col in 0..<width {
                let u = (CGFloat(col) + 0.5) / CGFloat(width)
                guard u >= rect.minX, u <= rect.maxX else { continue }
                if let ex = excluding, ex.contains(CGPoint(x: u, y: v)) { continue }
                picked.append(values[row * width + col])
            }
        }
        guard !picked.isEmpty else { return Stats(mean: 0, p90: 0, count: 0) }
        let mean = picked.reduce(0, +) / Float(picked.count)
        picked.sort()
        let p90 = picked[min(picked.count - 1, Int(Float(picked.count) * 0.9))]
        return Stats(mean: mean, p90: p90, count: picked.count)
    }
}

/// Everything measured on one frame.
struct FrameReading: Equatable {
    var cameraSize: CGSize
    var face: FaceMeasurement?
    var faceCount: Int
    var luma: LumaMap
}

// MARK: - The analyzer (Vision + luma), off the capture queue

/// Runs on a background task, never on the capture queue: the capture only
/// hands over its newest buffer (`CameraFrameTap`); this downsizes a copy to
/// 640 px wide and measures that.
final class FramingAnalyzer: @unchecked Sendable {
    static let analysisWidth: CGFloat = 640
    static let lumaCell = 8

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// `image` is the camera frame as recorded (CIImage, origin bottom-left).
    /// Also returns the downsized frame, reused for thumbnails.
    func analyze(_ image: CIImage) -> (FrameReading, CGImage)? {
        let extent = image.extent
        guard extent.width >= 16, extent.height >= 16 else { return nil }
        let scale = min(1, Self.analysisWidth / extent.width)
        let w = Int((extent.width * scale).rounded()), h = Int((extent.height * scale).rounded())
        let small = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(small, from: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: srgb)
        else { return nil }
        return analyze(cgImage: cg, cameraSize: extent.size).map { ($0, cg) }
    }

    func analyze(cgImage cg: CGImage, cameraSize: CGSize) -> FrameReading? {
        let w = cg.width, h = cg.height
        guard w >= 16, h >= 16 else { return nil }

        // Pixels, top row first (a bitmap context's memory starts at the top).
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        let luma = Self.lumaMap(pixels: pixels, width: w, height: h)

        // Faces: landmarks give the eye line (and a better roll than the box).
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        try? handler.perform([request])
        let faces = request.results ?? []
        let biggest = faces.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
        let face = biggest.map { Self.measure($0, aspect: CGFloat(w) / CGFloat(h)) }
        return FrameReading(cameraSize: cameraSize, face: face, faceCount: faces.count, luma: luma)
    }

    private static func measure(_ observation: VNFaceObservation, aspect: CGFloat) -> FaceMeasurement {
        let box = observation.boundingBox // normalised, bottom-left
        let face = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
        func point(_ p: CGPoint) -> CGPoint {
            CGPoint(x: box.minX + p.x * box.width, y: 1 - (box.minY + p.y * box.height))
        }
        func centre(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
            guard let region, region.pointCount > 0 else { return nil }
            let pts = region.normalizedPoints
            let sx = pts.reduce(0) { $0 + $1.x }, sy = pts.reduce(0) { $0 + $1.y }
            return point(CGPoint(x: sx / CGFloat(pts.count), y: sy / CGFloat(pts.count)))
        }
        let landmarks = observation.landmarks
        let a = centre(landmarks?.leftPupil) ?? centre(landmarks?.leftEye)
        let b = centre(landmarks?.rightPupil) ?? centre(landmarks?.rightEye)
        var eyes: (CGPoint, CGPoint)?
        var roll: CGFloat = 0
        if let a, let b {
            let pair = a.x <= b.x ? (a, b) : (b, a)
            eyes = pair
            // In pixel units, so a 16:9 frame does not skew the angle.
            let dx = (pair.1.x - pair.0.x) * aspect, dy = pair.1.y - pair.0.y
            roll = atan2(dy, dx) * 180 / .pi
        } else if let r = observation.roll?.doubleValue {
            roll = CGFloat(r) * 180 / .pi
        }
        return FaceMeasurement(
            face: face, eyes: eyes, rollDegrees: roll,
            pitchDegrees: observation.pitch.map { CGFloat($0.doubleValue) * 180 / .pi },
            yawDegrees: observation.yaw.map { CGFloat($0.doubleValue) * 180 / .pi }
        )
    }

    private static func lumaMap(pixels: [UInt8], width w: Int, height h: Int) -> LumaMap {
        let cell = lumaCell
        let gw = max(1, w / cell), gh = max(1, h / cell)
        var values = [Float](repeating: 0, count: gw * gh)
        for gy in 0..<gh {
            for gx in 0..<gw {
                var sum: Float = 0
                var n: Float = 0
                var y = gy * cell
                while y < min(h, (gy + 1) * cell) {
                    var x = gx * cell
                    while x < min(w, (gx + 1) * cell) {
                        let i = (y * w + x) * 4
                        sum += 0.2126 * Float(pixels[i]) + 0.7152 * Float(pixels[i + 1]) + 0.0722 * Float(pixels[i + 2])
                        n += 1
                        x += 2
                    }
                    y += 2
                }
                values[gy * gw + gx] = n > 0 ? sum / n / 255 : 0
            }
        }
        return LumaMap(width: gw, height: gh, values: values)
    }
}

// MARK: - Hints

/// Traffic light.
enum FramingStatus: Int, Comparable {
    case unknown = -1
    case good = 0
    case adjust = 1
    case fix = 2
    static func < (a: FramingStatus, b: FramingStatus) -> Bool { a.rawValue < b.rawValue }
}

/// What can be wrong, in the order hints are worth reading.
enum FramingIssueKind: Int, CaseIterable, Comparable {
    case noFace, headCut, chinCut, outOfCrop, tooDark, backlit, washedOut
    case tooClose, tooFar, eyesLow, eyesHigh, offLeft, offRight, tilted
    static func < (a: FramingIssueKind, b: FramingIssueKind) -> Bool { a.rawValue < b.rawValue }

    /// Pairs that pull in opposite directions (only one can be shown).
    var opposite: FramingIssueKind? {
        switch self {
        case .tooClose: return .tooFar
        case .tooFar: return .tooClose
        case .eyesLow: return .eyesHigh
        case .eyesHigh: return .eyesLow
        case .offLeft: return .offRight
        case .offRight: return .offLeft
        default: return nil
        }
    }
}

struct FramingIssue: Equatable {
    var kind: FramingIssueKind
    /// How far outside its band, in that metric's own units (> 0 = outside).
    var excess: CGFloat
    var major: Bool
}

/// Numbers measured inside one crop (for the report and the stage).
struct CropMetrics: Equatable {
    var faceHeight: CGFloat
    /// Face box width ÷ crop width.
    var faceWidth: CGFloat
    var eyeY: CGFloat
    var centreX: CGFloat
    var headTop: CGFloat
    var chin: CGFloat
    var roll: CGFloat
    var faceLuma: Float
    var backgroundLuma: Float
    var backgroundBright: Float
}

/// What one crop (or all of them together) says right now.
struct FramingAdvice: Equatable {
    var status: FramingStatus
    /// At most two short, plain-English lines.
    var hints: [String]

    static let waiting = FramingAdvice(status: .unknown, hints: ["Waiting for the camera…"])
    static let good = FramingAdvice(status: .good, hints: ["Looks good ✓"])
}

/// Hint rules. Thresholds are in one place so everything agrees.
enum FramingRules {
    /// Roll beyond this is "straighten the camera".
    static let rollLimit: CGFloat = 5
    /// Face noticeably darker than the room behind it (luma, 0…1).
    static let backlitGap: Float = 0.20
    /// …and only when the room really has a bright source (90th percentile).
    static let backlitBrightRoom: Float = 0.82
    static let backlitMajorGap: Float = 0.32
    static let darkFace: Float = 0.26
    static let veryDarkFace: Float = 0.16
    static let brightFace: Float = 0.86

    /// `hysteresis(kind)` true = this issue was showing: it has to come back
    /// clearly inside its band (not just to the edge) before it clears, which
    /// is what stops a hint flickering on the boundary.
    static func evaluate(
        _ reading: FrameReading, face m: FaceMeasurement, crop: ResolvedFramingCrop,
        wasActive: (FramingIssueKind) -> Bool
    ) -> (issues: [FramingIssue], metrics: CropMetrics) {
        let t = crop.target
        let box = crop.toCrop(m.face)
        let faceHeight = box.height
        let eyeY = crop.toCrop(CGPoint(x: 0, y: m.eyeY)).y
        let centreX = box.midX
        let headTop = crop.toCrop(CGPoint(x: 0, y: m.headTop)).y
        let chin = box.maxY

        // Brightness: skin vs the whole room behind the speaker (person cut out).
        // One fact for every crop, a narrow card sees only a strip of wall
        // above the head, and a white wall there is not a backlight.
        let skin = reading.luma.stats(in: m.skinRect)
        let background = reading.luma.stats(in: CGRect(x: 0, y: 0, width: 1, height: 1), excluding: m.personRect)
        let metrics = CropMetrics(
            faceHeight: faceHeight, faceWidth: box.width, eyeY: eyeY, centreX: centreX, headTop: headTop, chin: chin,
            roll: m.rollDegrees, faceLuma: skin.mean, backgroundLuma: background.mean,
            backgroundBright: background.p90
        )

        var issues: [FramingIssue] = []
        // Enter a little outside the band, leave a little inside it.
        func check(_ kind: FramingIssueKind, _ excess: CGFloat, enter: CGFloat, leave: CGFloat, major: CGFloat) {
            let active = wasActive(kind) ? excess > -leave : excess > enter
            if active { issues.append(FramingIssue(kind: kind, excess: max(excess, 0), major: excess > major)) }
        }

        // Cut-offs: the worst ones, always major.
        check(.headCut, -headTop, enter: 0.01, leave: 0.02, major: -1)
        check(.chinCut, chin - 1, enter: -0.01, leave: 0.02, major: -1)
        check(.outOfCrop, max(-box.minX, box.maxX - 1), enter: 0.0, leave: 0.03, major: -1)

        // Size of the face in the crop.
        check(.tooClose, faceHeight - t.faceHeight.upperBound, enter: 0.015, leave: 0.015, major: 0.08)
        check(.tooFar, t.faceHeight.lowerBound - faceHeight, enter: 0.015, leave: 0.015, major: 0.06)

        // Height: eyes on the upper-third band.
        check(.eyesLow, eyeY - t.eyeBand.upperBound, enter: 0.015, leave: 0.02, major: 0.10)
        check(.eyesHigh, t.eyeBand.lowerBound - eyeY, enter: 0.015, leave: 0.02, major: 0.10)

        // Sideways.
        check(.offLeft, (0.5 - centreX) - t.centreTolerance, enter: 0.01, leave: 0.02, major: 0.12)
        check(.offRight, (centreX - 0.5) - t.centreTolerance, enter: 0.01, leave: 0.02, major: 0.12)

        // Tilt.
        check(.tilted, (abs(m.rollDegrees) - rollLimit) / 10, enter: 0.0, leave: 0.1, major: 0.4)

        // Light.
        if skin.count > 0 {
            check(.tooDark, CGFloat(darkFace - skin.mean), enter: 0, leave: 0.03, major: CGFloat(darkFace - veryDarkFace))
            check(.washedOut, CGFloat(skin.mean - brightFace), enter: 0, leave: 0.03, major: 0.08)
            // Only a real backlight: the room is bright AND the face is well
            // below it. A white wall behind a well-lit face is fine.
            if background.count >= 12, background.p90 > backlitBrightRoom {
                let gap = background.mean - skin.mean
                check(.backlit, CGFloat(gap - backlitGap), enter: 0, leave: 0.04, major: CGFloat(backlitMajorGap - backlitGap))
            }
        }

        // Opposites can't both hold; keep the stronger (cut-offs already
        // say which way to go).
        issues = issues.filter { issue in
            guard let other = issue.kind.opposite,
                  let rival = issues.first(where: { $0.kind == other }) else { return true }
            return issue.excess >= rival.excess
        }
        if issues.contains(where: { $0.kind == .tooClose }) {
            // Too close is why the head is cut: "move back" fixes both.
            issues.removeAll { $0.kind == .headCut }
            if let i = issues.firstIndex(where: { $0.kind == .tooClose }), headTop < 0 { issues[i].major = true }
        }
        if issues.contains(where: { $0.kind == .headCut }) {
            issues.removeAll { $0.kind == .eyesHigh }
        }
        if issues.contains(where: { $0.kind == .chinCut }) {
            issues.removeAll { $0.kind == .tooClose || $0.kind == .eyesLow }
        }
        return (issues, metrics)
    }

    /// One line for an issue. `side` needs to know about mirroring: in a
    /// mirrored picture you move the way the picture should move (like a
    /// mirror); un-mirrored, the opposite way.
    static func message(_ kind: FramingIssueKind, major: Bool = false, mirrored: Bool, where place: String?) -> String {
        let suffix = place.map { " (\($0))" } ?? ""
        switch kind {
        case .noFace: return "Can't see your face, sit in front of the camera"
        case .headCut: return "Your head is cut off, tilt the camera up" + suffix
        case .chinCut: return "Your chin is cut off, move back" + suffix
        case .outOfCrop:
            return "You're running out of the frame" + suffix
        case .tooDark: return "Too dark, add a light in front of you"
        case .backlit: return "Too much light behind you, face the window or lamp"
        case .washedOut: return "Too bright on your face, soften the light"
        case .tooClose: return (major ? "Move back, too close" : "Move back a little, too close") + suffix
        case .tooFar: return (major ? "Move closer, too far" : "Move a little closer") + suffix
        // Eyes low in the picture = the camera aims too high: tilting it down
        // (or lowering it) lifts you in the frame. A tilt is the direction
        // that is right whether the phone sits above or below eye level.
        case .eyesLow: return (major ? "Tilt the camera down" : "Tilt the camera down a little") + suffix
        case .eyesHigh: return (major ? "Tilt the camera up" : "Tilt the camera up a little") + suffix
        case .offLeft, .offRight:
            // offLeft: the face sits left of centre, the picture must move right.
            let pictureRight = (kind == .offLeft)
            let yourRight = mirrored ? pictureRight : !pictureRight
            return (major ? "Move to your " : "Move a little to your ") + (yourRight ? "right" : "left") + suffix
        case .tilted: return "Straighten the camera (or your head)"
        }
    }

    /// Just me → Full: the long-form shot is wide so hand
    /// gestures show, and "too close" says why. Everything else is `message`.
    static func fullFrameMessage(_ kind: FramingIssueKind, major: Bool = false, mirrored: Bool, where place: String?) -> String {
        let suffix = place.map { " (\($0))" } ?? ""
        switch kind {
        case .tooClose:
            return (major ? "Move back, show your hands and the desk" : "Move back a little, let your hands show") + suffix
        default:
            return message(kind, major: major, mirrored: mirrored, where: place)
        }
    }

    /// Which way a face that runs out of a card has to go.
    static func outOfCropDirection(_ metrics: CropMetrics) -> FramingIssueKind {
        metrics.centreX < 0.5 ? .offLeft : .offRight
    }

    static func status(for issues: [FramingIssue]) -> FramingStatus {
        if issues.isEmpty { return .good }
        return issues.contains(where: { $0.major }) ? .fix : .adjust
    }
}

// MARK: - The coach: smoothing, hysteresis, calm hints

/// Everything the UI needs after one analysis step.
struct FramingReport: Equatable {
    var overall: FramingAdvice
    var perCrop: [FramingAdvice]
    var metrics: [CropMetrics?]
    var crops: [ResolvedFramingCrop]
    /// The smoothed face (for drawing the live eye line).
    var face: FaceMeasurement?
    var cameraSize: CGSize

    static let idle = FramingReport(overall: .waiting, perCrop: [], metrics: [], crops: [], face: nil, cameraSize: .zero)
}

/// Turns a stream of noisy readings into calm advice: the face is smoothed
/// (EMA), each issue has hysteresis, and a new set of hints must hold for
/// `settle` seconds, and the old one must have been up for `minShow`. /// before the display changes. One wobbly frame never changes what you see.
final class FramingCoach {
    var smoothing: CGFloat = 0.35
    var settle: TimeInterval = 1.0
    var minShow: TimeInterval = 1.6
    var faceLostAfter: TimeInterval = 1.2

    private var face: FaceMeasurement?
    private var lastFaceTime: TimeInterval = -.infinity
    private var active: [FramingCropSpec: Set<FramingIssueKind>] = [:]
    private var shown: [String: (advice: FramingAdvice, since: TimeInterval)] = [:]
    private var pending: [String: (advice: FramingAdvice, since: TimeInterval)] = [:]

    func reset() {
        face = nil
        lastFaceTime = -.infinity
        active = [:]
        shown = [:]
        pending = [:]
    }

    /// One step. `instant` = no smoothing, no hysteresis, no debounce (for
    /// looking at single stills). `message` formats one
    /// issue into a line, default is the Just me / Screen wording
    /// (`FramingRules.message`); Short mode passes `ShortFramingHints.message`
    /// so its coaching reads in its own voice without touching this shared
    /// engine's default behaviour for every other caller.
    func step(
        _ reading: FrameReading?, specs: [FramingCropSpec], mirrored: Bool,
        now: TimeInterval, instant: Bool = false,
        message custom: ((FramingIssueKind, Bool, Bool, String?) -> String)? = nil,
        good: FramingAdvice = .good
    ) -> FramingReport {
        guard let reading else { return .idle }
        // nil = the shared wording; Just me → Full alone gets the "show your hands" variant.
        let message = custom ?? (specs == [.fullFrame] ? FramingRules.fullFrameMessage : FramingRules.message)
        let crops = specs.compactMap { $0.resolve(cameraSize: reading.cameraSize) }

        // Smooth the face; hold it briefly through a missed detection.
        if let fresh = reading.face {
            if instant || face == nil || now - lastFaceTime > faceLostAfter {
                face = fresh
            } else if let old = face {
                face = Self.blend(old, fresh, smoothing)
            }
            lastFaceTime = now
        } else if instant || now - lastFaceTime > faceLostAfter {
            face = nil
        }

        var perCropIssues: [[FramingIssue]] = []
        var metrics: [CropMetrics?] = []
        for crop in crops {
            guard let face else {
                perCropIssues.append([FramingIssue(kind: .noFace, excess: 1, major: true)])
                metrics.append(nil)
                continue
            }
            let was = instant ? [] : (active[crop.spec] ?? [])
            var (issues, m) = FramingRules.evaluate(reading, face: face, crop: crop, wasActive: { was.contains($0) })
            active[crop.spec] = Set(issues.map(\.kind))
            // A face running out of a card is a sideways move, said plainly
            // (a major one: "Move to your right", not "a little").
            // Unless the face is simply wider than the card: that is "too close".
            if issues.contains(where: { $0.kind == .outOfCrop }) {
                issues.removeAll { $0.kind == .outOfCrop || $0.kind == .offLeft || $0.kind == .offRight }
                if m.faceWidth >= 0.8 {
                    issues.removeAll { $0.kind == .tooClose || $0.kind == .tooFar }
                    issues.append(FramingIssue(kind: .tooClose, excess: 1, major: true))
                } else {
                    issues.append(FramingIssue(kind: FramingRules.outOfCropDirection(m), excess: 1, major: true))
                }
            }
            perCropIssues.append(issues.sorted { $0.kind < $1.kind })
            metrics.append(m)
        }

        // Per-crop advice.
        var perCrop: [FramingAdvice] = []
        for issues in perCropIssues {
            let lines = Self.lines(for: issues.map { ($0, [String]()) }, mirrored: mirrored, cropCount: 1, message: message)
            perCrop.append(issues.isEmpty ? good : FramingAdvice(status: FramingRules.status(for: issues), hints: lines))
        }

        // Together: one framing that works in every crop. Same kind merged
        // (worst excess wins), and the crops it applies to are named when it
        // isn't all of them.
        var merged: [FramingIssueKind: (issue: FramingIssue, crops: [String])] = [:]
        for (index, issues) in perCropIssues.enumerated() {
            for issue in issues {
                var entry = merged[issue.kind] ?? (issue, [])
                if issue.excess > entry.issue.excess { entry.issue.excess = issue.excess }
                entry.issue.major = entry.issue.major || issue.major
                entry.crops.append(crops[index].name)
                merged[issue.kind] = entry
            }
        }
        // Opposites across crops (too close in one, too far in another): the
        // majors win, then the bigger miss.
        for kind in merged.keys {
            guard let other = kind.opposite, let a = merged[kind], let b = merged[other] else { continue }
            let keepA = (a.issue.major && !b.issue.major) || (a.issue.major == b.issue.major && a.issue.excess >= b.issue.excess)
            merged[keepA ? other : kind] = nil
        }
        let all = merged.values.sorted { $0.issue.kind < $1.issue.kind }
        // Majors first, then by reading order.
        let ordered = all.filter { $0.issue.major } + all.filter { !$0.issue.major }
        let overall = ordered.isEmpty
            ? good
            : FramingAdvice(
                status: FramingRules.status(for: ordered.map(\.issue)),
                hints: Self.lines(for: ordered.map { ($0.issue, $0.crops) }, mirrored: mirrored, cropCount: crops.count, message: message)
            )

        let report = FramingReport(
            overall: instant ? overall : debounce("all", overall, now: now),
            perCrop: instant ? perCrop : perCrop.enumerated().map { debounce(crops[$0.offset].name, $0.element, now: now) },
            metrics: metrics, crops: crops, face: face, cameraSize: reading.cameraSize
        )
        return report
    }

    private static func lines(
        for issues: [(FramingIssue, [String])], mirrored: Bool, cropCount: Int,
        message: (FramingIssueKind, Bool, Bool, String?) -> String
    ) -> [String] {
        var out: [String] = []
        for (issue, crops) in issues {
            let place: String? = (cropCount > 1 && !crops.isEmpty && crops.count < cropCount)
                ? crops.joined(separator: ", ") : nil
            let line = message(issue.kind, issue.major, mirrored, place)
            if !out.contains(line) { out.append(line) }
            if out.count == 2 { break }
        }
        return out
    }

    private func debounce(_ key: String, _ candidate: FramingAdvice, now: TimeInterval) -> FramingAdvice {
        guard let current = shown[key] else {
            shown[key] = (candidate, now)
            return candidate
        }
        if candidate == current.advice {
            pending[key] = nil
            return current.advice
        }
        if let p = pending[key], p.advice == candidate {
            if now - p.since >= settle, now - current.since >= minShow {
                shown[key] = (candidate, now)
                pending[key] = nil
                return candidate
            }
        } else {
            pending[key] = (candidate, now)
        }
        return current.advice
    }

    private static func blend(_ a: FaceMeasurement, _ b: FaceMeasurement, _ k: CGFloat) -> FaceMeasurement {
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * k }
        func mix(_ p: CGPoint, _ q: CGPoint) -> CGPoint { CGPoint(x: mix(p.x, q.x), y: mix(p.y, q.y)) }
        var out = b
        out.face = CGRect(x: mix(a.face.minX, b.face.minX), y: mix(a.face.minY, b.face.minY),
                          width: mix(a.face.width, b.face.width), height: mix(a.face.height, b.face.height))
        if let ea = a.eyes, let eb = b.eyes { out.eyes = (mix(ea.0, eb.0), mix(ea.1, eb.1)) }
        out.rollDegrees = mix(a.rollDegrees, b.rollDegrees)
        return out
    }
}
