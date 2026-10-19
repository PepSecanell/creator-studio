import CoreImage
import CoreVideo
import Foundation
import SwiftUI

// The small "what the export will look like" thumbnail under Motion when the
// look is Studio, so you can see how you will appear while recording. It is not an approximation: it runs the export's own
// `StudioRenderer`, background plate, window, shadow, `drawCard`, at
// thumbnail size, with a placeholder standing in for the screen and the live
// camera (or a silhouette when the camera is off) in the card.

/// Holds the newest camera frame: one buffer, swapped under a lock, no copy.
/// Written on the capture queue, read by the Studio layout preview.
final class CameraFrameTap: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?

    func store(_ buffer: CVPixelBuffer?) {
        lock.lock()
        self.buffer = buffer
        lock.unlock()
    }

    func latest() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}

/// Renders one preview frame. CoreImage only.
final class StudioLayoutPreviewRenderer {

    /// Rendered at 2x the thumbnail's on-screen size (360 pt wide).
    static let defaultSize = CGSize(width: 720, height: 405)

    let face: FaceLayout
    let background: StudioBackground
    let size: CGSize
    private let renderer: StudioRenderer
    private let base: CIImage
    private let context = CIContext(options: [.cacheIntermediates: false])

    init(face: FaceLayout, background: StudioBackground, size: CGSize = StudioLayoutPreviewRenderer.defaultSize) {
        self.face = face
        self.background = background
        self.size = size
        let screenSize = FaceCardFraming.referenceSize
        renderer = StudioRenderer(renderSize: size, screenSize: screenSize, face: face, background: background)
        let overview = ZoomTimeline.State(progress: 0, scale: 1, center: CGPoint(x: 0.5, y: 0.5))
        let drawn = renderer.drawBase(
            screen: Self.placeholderScreen(size: screenSize),
            time: 0, zoom: overview, pointer: nil, clicks: [], showClicks: false
        )
        // Bake the static part once; only the card changes per frame.
        if let cg = context.createCGImage(drawn, from: CGRect(origin: .zero, size: size)) {
            base = CIImage(cgImage: cg)
        } else {
            base = drawn
        }
    }

    /// `camera` nil = the silhouette placeholder.
    func render(camera: CIImage?, grade: Bool) -> CGImage? {
        let source = camera ?? Self.placeholderCamera
        let frame = renderer.drawCard(camera: source, alpha: 1, grade: grade, over: base)
        return context.createCGImage(frame, from: CGRect(origin: .zero, size: size))
    }

    // MARK: Placeholders

    /// A neutral stand-in for the screen: desktop, one app window, text bars.
    /// No traffic-light colours, brand palette only.
    static func placeholderScreen(size: CGSize) -> CIImage {
        let w = Int(size.width), h = Int(size.height)
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return CIImage(color: CIColor(red: 0.9, green: 0.88, blue: 0.85)).cropped(to: CGRect(origin: .zero, size: size)) }
        let W = size.width, H = size.height
        func fill(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ rect: CGRect, radius: CGFloat = 0) {
            ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        }
        fill(0.87, 0.85, 0.82, CGRect(x: 0, y: 0, width: W, height: H))
        let win = CGRect(x: 0.05 * W, y: 0.06 * H, width: 0.90 * W, height: 0.86 * H)
        fill(0.99, 0.98, 0.96, win, radius: 0.012 * H)
        let bar = CGRect(x: win.minX, y: win.maxY - 0.06 * H, width: win.width, height: 0.06 * H)
        fill(0.93, 0.91, 0.88, bar, radius: 0.012 * H)
        for i in 0..<3 {
            let d = 0.018 * H
            fill(0.78, 0.74, 0.70, CGRect(x: bar.minX + 0.02 * H + CGFloat(i) * 1.6 * d, y: bar.midY - d / 2, width: d, height: d), radius: d / 2)
        }
        let side = CGRect(x: win.minX, y: win.minY, width: 0.18 * W, height: win.height - bar.height)
        fill(0.95, 0.93, 0.90, side)
        let lines: [CGFloat] = [0.62, 0.48, 0.55, 0.40, 0.58, 0.35, 0.50]
        for (i, share) in lines.enumerated() {
            let y = bar.minY - 0.08 * H - CGFloat(i) * 0.075 * H
            fill(0.83, 0.80, 0.76, CGRect(x: side.maxX + 0.04 * W, y: y, width: share * (win.maxX - side.maxX - 0.08 * W), height: 0.022 * H), radius: 0.011 * H)
        }
        guard let image = ctx.makeImage() else { return .empty() }
        return CIImage(cgImage: image)
    }

    /// Head-and-shoulders silhouette on a warm wall, 16:9 like a webcam, so
    /// the card shows the crop even with the camera off.
    static let placeholderCamera: CIImage = {
        let w = 640, h = 360
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .empty() }
        ctx.setFillColor(StudioPalette.cg(StudioPalette.sand))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(StudioPalette.cg(StudioPalette.roseDeep))
        ctx.fillEllipse(in: CGRect(x: 320 - 150, y: -120, width: 300, height: 240))
        ctx.fillEllipse(in: CGRect(x: 320 - 62, y: 150, width: 124, height: 150))
        guard let image = ctx.makeImage() else { return .empty() }
        return CIImage(cgImage: image)
    }()
}

/// Pure display: the rendered thumbnail and its caption. Kept separate from
/// the live loop so a headless `ImageRenderer` snapshot can draw it.
struct StudioLayoutPreviewCard: View {
    let image: CGImage?
    let face: FaceLayout
    let cameraLive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.08))
                if let image {
                    Image(decorative: image, scale: 2)
                        .resizable()
                        .interpolation(.high)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12), lineWidth: 1))

            Text("Export preview, \(face == .tallLeft ? "tall card on the left" : "card bottom-right"). "
                 + (cameraLive ? "That is your camera, cropped exactly as the video will be."
                               : "Turn on the camera bubble to see yourself in the card."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The live thumbnail: rebuilt when the face card, background or grade
/// change, refreshed ~5x a second from the newest camera frame. Paused while
/// recording so it never competes with the capture.
struct StudioLayoutPreview: View {
    let face: FaceLayout
    let background: StudioBackground
    let grade: Bool
    let paused: Bool
    let cameraLive: Bool
    let frameTap: CameraFrameTap

    @State private var image: CGImage?

    private struct Key: Hashable {
        let face: FaceLayout
        let background: StudioBackground
        let grade: Bool
        let paused: Bool
        let cameraLive: Bool
    }

    var body: some View {
        StudioLayoutPreviewCard(image: image, face: face, cameraLive: cameraLive)
            .task(id: Key(face: face, background: background, grade: grade, paused: paused, cameraLive: cameraLive)) {
                let face = self.face, background = self.background, grade = self.grade
                let renderer = await Task.detached(priority: .utility) {
                    StudioLayoutPreviewRenderer(face: face, background: background)
                }.value
                repeat {
                    let frame = cameraLive ? frameTap.latest() : nil
                    let rendered = await Task.detached(priority: .utility) {
                        renderer.render(camera: frame.map { CIImage(cvPixelBuffer: $0) }, grade: grade)
                    }.value
                    if Task.isCancelled { return }
                    image = rendered
                    // Nothing live to follow: one frame is enough.
                    if paused || !cameraLive { return }
                    try? await Task.sleep(for: .milliseconds(200))
                } while !Task.isCancelled
            }
    }
}
