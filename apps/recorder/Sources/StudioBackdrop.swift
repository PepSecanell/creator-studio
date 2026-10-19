import CoreGraphics
import CoreImage
import Foundation

// Background presets for the Studio layout.
//
// Six light backgrounds from design mockups. Each light preset here is
// a line-by-line translation of a mockup's CSS into Core Graphics, drawn in
// the mockup's own 1920x1080 CSS coordinates (y down) and scaled to the export
// size, so the plate matches the mockup at any resolution. The dark lit room
// from the first pass stays as the 7th preset.

/// Which background the Studio layout sits on.
enum StudioBackground: String, CaseIterable, Identifiable {
    case linen = "Linen"
    case blushMesh = "Blush mesh"
    case clay = "Clay"
    case sunlitStudio = "Sunlit studio"
    case dotPaper = "Dot paper"
    case silkWaves = "Silk waves"
    case darkRoom = "Dark room"

    var id: String { rawValue }

    /// The default (one line to change): Blush mesh,
    /// with the tall-left card (`FaceLayout.standard`). Used by the app (first
    /// launch) and the re-export CLI.
    static let standard: StudioBackground = .blushMesh

    /// Light presets use the mockup framing (window ~78% wide, fully visible)
    /// and a warm, soft chrome; the dark room keeps the 92% bleed and glass glow.
    var isLight: Bool { self != .darkRoom }

    /// CLI spelling: "linen", "1", "blush", "clay", "sunlit", "dots", "silk", "dark".
    init?(argument: String) {
        switch argument.lowercased() {
        case "1", "linen": self = .linen
        case "2", "blush", "blush-mesh", "mesh": self = .blushMesh
        case "3", "clay": self = .clay
        case "4", "sunlit", "sunlit-studio", "sun": self = .sunlitStudio
        case "5", "dots", "dot-paper", "dot": self = .dotPaper
        case "6", "silk", "silk-waves", "waves": self = .silkWaves
        case "7", "dark", "dark-room", "room": self = .darkRoom
        default:
            guard let match = StudioBackground(rawValue: argument) else { return nil }
            self = match
        }
    }
}

enum StudioBackdrop {

    /// A plate for a light preset, `over` times the frame size (so the drift
    /// and the parallax push never show an edge), positioned so the frame
    /// occupies (0,0)-(size) in Core Image space.
    static func makeLightPlate(_ preset: StudioBackground, size: CGSize, over: CGFloat = 1.10) -> CIImage {
        let fw = size.width, fh = size.height
        let width = Int((fw * over).rounded()), height = Int((fh * over).rounded())
        let ox = (CGFloat(width) - fw) / 2, oy = (CGFloat(height) - fh) / 2
        guard let ctx = context(width: width, height: height) else { return .empty() }

        // CSS space: 1920x1080, origin at the frame's top-left, y down.
        let sx = fw / 1920, sy = fh / 1080
        let css = CGAffineTransform(translationX: ox, y: CGFloat(height) - oy).scaledBy(x: sx, y: -sy)
        ctx.concatenate(css)
        // The whole oversized canvas, in CSS units.
        let canvas = CGRect(x: -ox / sx, y: -oy / sy, width: CGFloat(width) / sx, height: CGFloat(height) / sy)
        let painter = Painter(ctx: ctx, canvas: canvas, css: css, pixelSize: CGSize(width: width, height: height), unit: sy)

        switch preset {
        case .linen:
            painter.fill(0xF3EBDD)
            painter.radial(rx: 0.70, ry: 0.60, at: (0.12, 0.00), rgb: (233, 190, 172), alpha: 0.55)
            painter.radial(rx: 0.60, ry: 0.60, at: (1.00, 1.00), rgb: (214, 196, 164), alpha: 0.55)

        case .blushMesh:
            painter.fill(0xF5E9DC)
            painter.blurred(sigma: 90) { c in
                for (rect, hex) in [
                    (CGRect(x: -200, y: -260, width: 1100, height: 900), 0xFBF3EA),
                    (CGRect(x: 900, y: -200, width: 1200, height: 800), 0xEDC4B4),
                    (CGRect(x: -100, y: 500, width: 1100, height: 800), 0xE8D5B8),
                    (CGRect(x: 1100, y: 600, width: 1000, height: 700), 0xF0CFC0)
                ] {
                    c.setFillColor(hexColor(hex))
                    c.fillEllipse(in: rect)
                }
            }

        case .clay:
            painter.linear(degrees: 160, stops: [(0, 0xE2B19F, 1), (0.55, 0xCF9784, 1), (1, 0xBF8472, 1)])
            painter.radial(rx: 0.60, ry: 0.50, at: (0.50, -0.05), rgb: (255, 236, 224), alpha: 0.60)

        case .sunlitStudio:
            painter.linear(degrees: 120, stops: [(0, 0xFBF1E2, 1), (0.60, 0xF4E2CC, 1), (1, 0xEBD3BA, 1)])
            // Window light: soft slats falling across the wall, multiplied.
            painter.blurred(sigma: 14, blend: .multiply) { c in
                let element = CGRect(x: -300, y: -500, width: 2900, height: 2500)
                c.translateBy(x: element.midX, y: element.midY)
                c.rotate(by: -26 * .pi / 180)
                c.translateBy(x: -element.width / 2, y: -element.height / 2)
                let stripe = gradient([
                    (0, rgb(150, 96, 62), 0), (20.0 / 90, rgb(150, 96, 62), 0.20),
                    (70.0 / 90, rgb(150, 96, 62), 0.20), (1, rgb(150, 96, 62), 0)
                ])
                var x: CGFloat = 0
                while x < element.width {
                    c.saveGState()
                    c.clip(to: CGRect(x: x + 230, y: 0, width: 90, height: element.height))
                    c.drawLinearGradient(stripe, start: CGPoint(x: x + 230, y: 0), end: CGPoint(x: x + 320, y: 0), options: [])
                    c.restoreGState()
                    x += 420
                }
            }
            painter.radial(rx: 0.80, ry: 0.70, at: (0.80, 0.20), rgb: (236, 190, 160), alpha: 0.45)
            painter.linear(degrees: 180, stops: [(0.60, 0x96_6E_50, 0), (1, 0x96_6E_50, 0.12)])

        case .dotPaper:
            painter.fill(0xF5EDD8)
            // A fine dot grid.
            ctx.setFillColor(CGColor(srgbRed: 140 / 255, green: 94 / 255, blue: 72 / 255, alpha: 0.28))
            let pitch: CGFloat = 34, r: CGFloat = 1.7
            var y = (canvas.minY / pitch).rounded(.down) * pitch + 17
            while y < canvas.maxY {
                var x = (canvas.minX / pitch).rounded(.down) * pitch + 17
                while x < canvas.maxX {
                    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                    x += pitch
                }
                y += pitch
            }
            painter.radial(rx: 0.60, ry: 0.55, at: (0.85, 0.10), rgb: (226, 170, 150), alpha: 0.45)
            painter.radial(rx: 0.60, ry: 0.60, at: (0.00, 1.00), rgb: (212, 190, 150), alpha: 0.40)

        case .silkWaves:
            painter.linear(degrees: 135, stops: [(0, 0xF7EDE3, 1), (0.50, 0xF1DDD0, 1), (1, 0xEFD9C4, 1)])
            painter.blurred(sigma: 14) { c in
                // CSS: an elliptical ring = a border-box ellipse with a border.
                for (rect, border, color) in [
                    (CGRect(x: -600, y: -900, width: 2600, height: 1500), 90.0, rgb(255, 252, 248, 0.95)),
                    (CGRect(x: -300, y: -500, width: 2600, height: 1400), 130.0, rgb(222, 160, 138, 0.62)),
                    (CGRect(x: -800, y: 300, width: 2800, height: 1500), 100.0, rgb(255, 250, 244, 0.85)),
                    (CGRect(x: 200, y: 500, width: 2600, height: 1300), 150.0, rgb(206, 150, 120, 0.50))
                ] as [(CGRect, Double, CGColor)] {
                    let b = CGFloat(border)
                    c.setStrokeColor(color)
                    c.setLineWidth(b)
                    c.strokeEllipse(in: rect.insetBy(dx: b / 2, dy: b / 2))
                }
            }

        case .darkRoom:
            break
        }

        guard let image = ctx.makeImage() else { return .empty() }
        let grained = preset == .dotPaper ? image : addGrain(image, amplitude: 5) ?? image
        return GPUResident.image(grained).transformed(by: CGAffineTransform(translationX: -ox, y: -oy))
    }

    // MARK: - Painter

    /// Draws CSS background layers into the plate context.
    private struct Painter {
        let ctx: CGContext
        let canvas: CGRect
        let css: CGAffineTransform
        let pixelSize: CGSize
        /// Output pixels per CSS pixel (for blur radii).
        let unit: CGFloat

        func fill(_ hex: Int) {
            ctx.setFillColor(hexColor(hex))
            ctx.fill(canvas)
        }

        /// `radial-gradient(ellipse RX% RY% at CX% CY%, color, transparent 70%)`.
        func radial(rx: CGFloat, ry: CGFloat, at c: (CGFloat, CGFloat), rgb c3: (CGFloat, CGFloat, CGFloat), alpha: CGFloat) {
            let color = [c3.0 / 255, c3.1 / 255, c3.2 / 255]
            ctx.saveGState()
            ctx.translateBy(x: c.0 * 1920, y: c.1 * 1080)
            ctx.scaleBy(x: rx * 1920, y: ry * 1080)
            ctx.drawRadialGradient(
                gradient([(0, color, alpha), (0.70, color, 0)]),
                startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: []
            )
            ctx.restoreGState()
        }

        /// `linear-gradient(Ndeg, ...)` over the 1920x1080 frame; stops are
        /// (position, hex, alpha) and extend past both ends like CSS.
        func linear(degrees: CGFloat, stops: [(CGFloat, Int, CGFloat)]) {
            let a = degrees * .pi / 180
            let dir = CGPoint(x: sin(a), y: -cos(a))   // CSS: 0deg = up, y down
            let length = abs(1920 * sin(a)) + abs(1080 * cos(a))
            let centre = CGPoint(x: 960, y: 540)
            let start = CGPoint(x: centre.x - dir.x * length / 2, y: centre.y - dir.y * length / 2)
            let end = CGPoint(x: centre.x + dir.x * length / 2, y: centre.y + dir.y * length / 2)
            ctx.drawLinearGradient(
                gradient(stops.map { ($0.0, hexComponents($0.1), $0.2) }),
                start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }

        /// Draw shapes in CSS space into their own layer, Gaussian-blur it
        /// (CSS `filter: blur(N)` = sigma N) and composite it with `blend`.
        func blurred(sigma: CGFloat, blend: CGBlendMode = .normal, _ draw: (CGContext) -> Void) {
            let w = Int(pixelSize.width), h = Int(pixelSize.height)
            guard let layer = context(width: w, height: h) else { return }
            layer.concatenate(css)
            draw(layer)
            guard let sharp = layer.makeImage() else { return }
            let extent = CGRect(x: 0, y: 0, width: w, height: h)
            let soft = CIImage(cgImage: sharp)
                .clampedToExtent()
                .applyingGaussianBlur(sigma: Double(sigma * unit))
                .cropped(to: extent)
            guard let blurredImage = StudioBackdrop.renderer.createCGImage(
                soft, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
            ) else { return }
            ctx.saveGState()
            ctx.concatenate(css.inverted())
            ctx.setBlendMode(blend)
            ctx.draw(blurredImage, in: extent)
            ctx.restoreGState()
        }
    }

    fileprivate static let renderer = CIContext(options: [.cacheIntermediates: false])

    // MARK: - Helpers

    fileprivate static func context(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: max(width, 1), height: max(height, 1),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    /// Fine luminance grain (the mockups' multiply texture); also dithers the
    /// long gradients so H.264 cannot band them.
    private static func addGrain(_ image: CGImage, amplitude: Double) -> CGImage? {
        let width = image.width, height = image.height
        guard let ctx = context(width: width, height: height) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = ctx.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * height)
        var noise = SeededRandom(seed: 0x11_6E_A5)
        for row in 0..<height {
            let base = row * ctx.bytesPerRow
            for col in 0..<width {
                let n = Int((noise.next() - 0.55) * amplitude)
                let p = base + col * 4
                for ch in 0..<3 { bytes[p + ch] = UInt8(clamping: Int(bytes[p + ch]) + n) }
            }
        }
        return ctx.makeImage()
    }
}

private func hexComponents(_ hex: Int) -> [CGFloat] {
    [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255]
}

private func hexColor(_ hex: Int, _ alpha: CGFloat = 1) -> CGColor {
    let c = hexComponents(hex)
    return CGColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: alpha)
}

private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> [CGFloat] { [r / 255, g / 255, b / 255] }

private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

private func gradient(_ stops: [(CGFloat, [CGFloat], CGFloat)]) -> CGGradient {
    var components: [CGFloat] = []
    var locations: [CGFloat] = []
    for (location, color, alpha) in stops {
        components += [color[0], color[1], color[2], alpha]
        locations.append(location)
    }
    return CGGradient(
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colorComponents: components, locations: locations, count: locations.count
    )!
}
