import CoreGraphics
import CoreImage
import Foundation

// The "Studio" screen-share look.
//
// The screen sits as a rounded glass-edged window in a dark, warmly lit room
// for overview moments, and fills the frame when the camera pushes in. The
// face is a designed card in a fixed slot. Material: near-black → chocolate
// room, a warm rose bloom, a faint diagonal beam, vignette and grain, a
// luminous cream edge brighter on top, soft deep shadows.

/// How the screen is presented in the finished file.
enum ScreenLayout: String, CaseIterable, Identifiable {
    /// Framed window on the lit room, camera pushes in to full frame.
    case studio = "Studio"
    /// The classic look: full-bleed screen, bubble where it was dragged.
    case classic = "Classic"
    var id: String { rawValue }
}

/// Where the face card lives in the Studio layout. Chosen per recording.
enum FaceLayout: String, CaseIterable, Identifiable {
    /// Rounded card in a fixed bottom-right slot (reference 2).
    case bottomRight = "Bottom-right"
    /// Tall portrait card flush to the left edge, screen beside it (reference 1).
    case tallLeft = "Tall left"
    var id: String { rawValue }

    /// The default: tall card left, on Blush mesh
    /// (`StudioBackground.standard`). Bottom-right stays selectable per video.
    static let standard: FaceLayout = .tallLeft

    /// Parses the CLI spelling too ("bottom-right", "tall-left").
    init?(argument: String) {
        switch argument.lowercased() {
        case "bottom-right", "bottomright", "br", "bottom-right card": self = .bottomRight
        case "tall-left", "tallleft", "tl", "left": self = .tallLeft
        default:
            guard let match = FaceLayout(rawValue: argument) else { return nil }
            self = match
        }
    }
}

/// Brand colours as sRGB components.
enum StudioPalette {
    static let ink: [CGFloat] = [0.043, 0.020, 0.008]        // #0B0502
    static let chocolate: [CGFloat] = [0.173, 0.082, 0.031]  // #2C1508
    static let chocolateLift: [CGFloat] = [0.235, 0.118, 0.059]
    static let cream: [CGFloat] = [0.961, 0.929, 0.847]      // #F5EDD8
    static let rose: [CGFloat] = [0.831, 0.643, 0.604]       // #D4A49A
    static let roseDeep: [CGFloat] = [0.776, 0.545, 0.494]   // #C68B7E
    static let sand: [CGFloat] = [0.851, 0.757, 0.639]       // sand

    static func cg(_ c: [CGFloat], _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: alpha)
    }
}

// MARK: - Geometry

/// Where everything sits, in output pixels, origin bottom-left (Core Image).
struct StudioGeometry: Equatable {
    let size: CGSize
    let face: FaceLayout
    let background: StudioBackground
    /// The screen window in the overview state.
    let windowRect: CGRect
    let windowRadius: CGFloat
    /// The face card slot.
    let cardRect: CGRect
    let cardRadius: CGFloat
    /// Light presets: a cream rim around the card (mockup: 5px #FBF6EE).
    let cardRim: CGFloat
    /// A zoomed focus is centred in here, so it never lands under the card.
    let safeArea: CGRect
    let edgeWidth: CGFloat

    var light: Bool { background.isLight }

    init(size: CGSize, screenAspect: CGFloat, face: FaceLayout, background: StudioBackground = .darkRoom) {
        let W = size.width, H = size.height
        let aspect = screenAspect > 0 ? screenAspect : W / max(H, 1)
        self.size = size
        self.face = face
        self.background = background
        self.edgeWidth = max(1.5, 1.6 * H / 1080)

        if background.isLight {
            // The mockup framing (bg-options/index.html), in its 1920x1080
            // units: the whole window is visible on the background, the
            // 92%-wide bleed hid the background these presets exist to show.
            let u = H / 1080
            switch face {
            case .bottomRight:
                windowRadius = 24 * u
                cardRim = 5 * u
                // #win left 170 top 92, 1500 wide; #face right 70 bottom 60, 360x330, r30.
                let width = 1500 * W / 1920
                let height = width / aspect
                windowRect = CGRect(x: 170 * W / 1920, y: H - 92 * u - height, width: width, height: height)
                cardRect = CGRect(x: W - (70 + 360) * u, y: 60 * u, width: 360 * u, height: 330 * u)
                cardRadius = 30 * u
                safeArea = CGRect(origin: .zero, size: size)
            case .tallLeft:
                // Approved mockup (#stage.tall, measured off the reference
                // frame): NOTHING touches the frame edge, every corner is
                // rounded and visible. Card left 14, top 240, 318x600, r30,
                // 4px rim; window left 348, top 101, 1560 wide (~12px right
                // margin), r32.
                cardRect = CGRect(x: 14 * u, y: H - (240 + 600) * u, width: 318 * u, height: 600 * u)
                cardRadius = 30 * u
                windowRadius = 32 * u
                cardRim = 4 * u
                let width = 1560 * W / 1920
                let height = width / aspect
                windowRect = CGRect(x: 348 * W / 1920, y: H - 101 * u - height, width: width, height: height)
                safeArea = windowRect
            }
            return
        }

        cardRim = 0
        windowRadius = 0.020 * H
        switch face {
        case .bottomRight:
            // ~92% wide, bleeding off the bottom (design decision 1).
            let width = 0.920 * W
            let height = width / aspect
            let top = 0.085 * H
            windowRect = CGRect(x: (W - width) / 2, y: H - top - height, width: width, height: height)
            let side = 0.285 * H
            let margin = 0.034 * H
            cardRect = CGRect(x: W - margin - side, y: margin, width: side, height: side)
            cardRadius = 0.20 * side
            safeArea = CGRect(origin: .zero, size: size)

        case .tallLeft:
            // Portrait card flush to the left edge; the window beside it
            // bleeds off the right and the bottom (reference 1).
            let top = 0.105 * H
            let cardVisibleWidth = 0.205 * W
            let cardHeight = 0.64 * H
            let radius = 0.030 * H
            // The left corners sit off-frame, so the card reads as flush.
            cardRect = CGRect(
                x: -radius * 1.5, y: H - top - cardHeight,
                width: cardVisibleWidth + radius * 1.5, height: cardHeight
            )
            cardRadius = radius
            let gap = 0.022 * W
            let x = cardVisibleWidth + gap
            let width = 0.905 * W
            let height = width / aspect
            windowRect = CGRect(x: x, y: H - top - height, width: width, height: height)
            safeArea = CGRect(x: x, y: 0, width: W - x, height: H)
        }
    }

    /// The overview window for a framed region of the screen (normalised,
    /// origin bottom-left; `FocusPath.full` = the whole screen). The region
    /// is aspect-fitted into the visible part of `windowRect` (or of `window`,
    /// the dynamic layout's current window rect, when given).
    func overviewRect(for region: CGRect, screenAspect: CGFloat, window: CGRect? = nil) -> CGRect {
        let windowRect = window ?? self.windowRect
        guard region != FocusPath.full, region.width > 0, region.height > 0 else { return windowRect }
        var box = windowRect.intersection(CGRect(origin: .zero, size: size))
        if !light {
            // The dark layout bleeds off the bottom; keep a framed window clear of it.
            let bottom = max(box.minY, 0.05 * size.height)
            box = CGRect(x: box.minX, y: bottom, width: box.width, height: box.maxY - bottom)
        }
        let aspect = region.width * screenAspect / region.height
        var w = box.width, h = w / aspect
        if h > box.height { h = box.height; w = h * aspect }
        return CGRect(x: box.midX - w / 2, y: box.maxY - h - (box.height - h) * (light ? 0.5 : 0.35), width: w, height: h)
    }

    /// The fixed layout as a frame: exactly today's window and card.
    var fixedFrame: StudioLayoutFrame {
        StudioLayoutFrame(
            windowRect: windowRect, windowRadius: windowRadius,
            cardRect: cardRect, cardRadius: cardRadius, cardRim: cardRim
        )
    }

    /// Where the window and the card sit in each dynamic-layout state
    ///. Same two elements in every state, only their rects and
    /// radii change, so a change of state is one
    /// morph, never a cut. Numbers are in the mockup's 1920x1080 units and
    /// follow the light-preset rules: every corner rounded and visible, even
    /// margins, nothing touching the frame edge. `.screen` IS the fixed
    /// layout. The dark room has no dynamic states (it bleeds off the frame
    /// by design), so every state there is the fixed frame.
    func layoutFrame(_ state: LayoutState) -> StudioLayoutFrame {
        let fixed = fixedFrame
        guard light, state != .screen else { return fixed }
        let W = size.width, H = size.height
        let u = H / 1080
        let aspect = windowRect.width / max(windowRect.height, 1)
        // Tall-left keeps the speaker on the left in every state, bottom-right on the
        // right, so a morph never sends the card across the screen.
        let cardLeft = face == .tallLeft
        switch state {
        case .screen:
            return fixed

        case .split:
            // Face card large on its side, the window smaller beside it,
            // vertically centred. Even 40-unit margins and gap.
            let m = 40 * u
            let cardW = 900 * W / 1920
            let cardH = H - 2 * m
            let winW = W - 3 * m - cardW
            let winH = winW / aspect
            let cardX = cardLeft ? m : W - m - cardW
            let winX = cardLeft ? 2 * m + cardW : m
            return StudioLayoutFrame(
                windowRect: CGRect(x: winX, y: (H - winH) / 2, width: winW, height: winH),
                windowRadius: 24 * u,
                cardRect: CGRect(x: cardX, y: m, width: cardW, height: cardH),
                cardRadius: 34 * u, cardRim: 5 * u
            )

        case .face:
            // Speaker large on the background, even margins all round. The window
            // slides in under the growing card and ends fully behind it (the
            // card is always drawn on top), no half-transparent ghost of the
            // screen mid-move; on the way out it emerges from behind the card.
            let m = 56 * u
            let card = CGRect(x: m, y: m, width: W - 2 * m, height: H - 2 * m)
            let winW = windowRect.width * 0.5
            let winH = winW / aspect
            return StudioLayoutFrame(
                windowRect: CGRect(x: card.midX - winW / 2, y: card.midY - winH / 2, width: winW, height: winH),
                windowRadius: windowRadius * 0.6,
                cardRect: card, cardRadius: 38 * u, cardRim: 5 * u
            )

        case .focus:
            // The window grows to nearly the whole frame and the card tucks
            // into its corner, smaller, overlapping the window's corner the
            // way the bottom-right card always has.
            let m = 34 * u
            var winH = H - 2 * m
            var winW = winH * aspect
            if winW > W - 2 * m { winW = W - 2 * m; winH = winW / aspect }
            let win = CGRect(x: (W - winW) / 2, y: (H - winH) / 2, width: winW, height: winH)
            let cm = 22 * u
            let card = cardLeft
                ? CGRect(x: cm, y: cm, width: 190 * u, height: 330 * u)
                : CGRect(x: W - cm - 280 * u, y: cm, width: 280 * u, height: 256 * u)
            return StudioLayoutFrame(
                windowRect: win, windowRadius: 28 * u,
                cardRect: card, cardRadius: 26 * u, cardRim: 4 * u
            )
        }
    }
}

/// The arrangements the dynamic layout moves between.
enum LayoutState: String, CaseIterable, Codable {
    /// Speaker large on the background, no screen: intro, outro, long talk.
    case face = "FACE"
    /// Face card large beside a smaller window: talking about what is on screen.
    case split = "SPLIT"
    /// Today's layout (tall-left or bottom-right card + window).
    case screen = "SCREEN"
    /// Window near full frame, card small in its corner: a long zoomed stretch.
    case focus = "FOCUS"
}

/// Where the window and the face card are at one instant, output pixels,
/// origin bottom-left. Interpolated between two states during a morph.
struct StudioLayoutFrame: Equatable {
    var windowRect: CGRect
    var windowRadius: CGFloat
    var cardRect: CGRect
    var cardRadius: CGFloat
    var cardRim: CGFloat

    static func lerp(_ a: StudioLayoutFrame, _ b: StudioLayoutFrame, _ t: CGFloat) -> StudioLayoutFrame {
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * t }
        func mix(_ r: CGRect, _ s: CGRect) -> CGRect {
            CGRect(x: mix(r.minX, s.minX), y: mix(r.minY, s.minY),
                   width: mix(r.width, s.width), height: mix(r.height, s.height))
        }
        return StudioLayoutFrame(
            windowRect: mix(a.windowRect, b.windowRect),
            windowRadius: mix(a.windowRadius, b.windowRadius),
            cardRect: mix(a.cardRect, b.cardRect),
            cardRadius: mix(a.cardRadius, b.cardRadius),
            cardRim: mix(a.cardRim, b.cardRim)
        )
    }
}

/// One instant of the layout timeline: moving `from` → `to`, `t` eased 0…1.
/// A settled state is `from == to`.
struct LayoutBlend: Equatable {
    let from: LayoutState
    let to: LayoutState
    let t: CGFloat

    static func settled(_ state: LayoutState) -> LayoutBlend { LayoutBlend(from: state, to: state, t: 1) }
}

/// How a camera frame is cropped into the face card, the ONE definition,
/// shared by the export (`StudioRenderer.drawCard`), the live camera bubble
/// (`CameraBubbleWindow` in Studio) and the settings-panel layout preview.
/// You cannot know how you appear when recording unless the live bubble shows
/// the same crop: the bubble was a circle while the export was a tall card. If this
/// is changed, all three move together; nothing else may re-derive the crop.
///
/// Output pixels, origin bottom-left (Core Image).
struct FaceCardFraming: Equatable {
    /// The whole card (the dark tall-left card runs off the left edge).
    let cardRect: CGRect
    let cardRadius: CGFloat
    /// The part of the card that is actually inside the frame.
    let visibleRect: CGRect
    /// Camera pixels → output pixels.
    let scale: CGFloat
    /// Where the whole scaled camera frame lands; `cardRect` crops it.
    let cameraRect: CGRect

    init?(geometry: StudioGeometry, cameraSize: CGSize) {
        self.init(
            cardRect: geometry.cardRect, cardRadius: geometry.cardRadius,
            frameSize: geometry.size, cameraSize: cameraSize
        )
    }

    /// Any card rect, the dynamic layout's larger / differently shaped cards
    /// (SPLIT, FACE, FOCUS and every frame of a morph) go through this same
    /// crop, so there is still exactly one definition of it.
    init?(cardRect rect: CGRect, cardRadius: CGFloat, frameSize: CGSize, cameraSize: CGSize) {
        guard cameraSize.width > 0, cameraSize.height > 0, rect.width > 0, rect.height > 0 else { return nil }
        // Aspect-fill the card.
        let scale = max(rect.width / cameraSize.width, rect.height / cameraSize.height)
        let width = cameraSize.width * scale, height = cameraSize.height * scale
        // Centre on the part of the card that is actually on screen (the
        // tall-left card's left corners sit off-frame), without uncovering it.
        let visible = rect.intersection(CGRect(origin: .zero, size: frameSize))
        let slackX = (width - rect.width) / 2
        let shiftX = min(max(visible.midX - rect.midX, -slackX), slackX)
        // Portrait card from a landscape camera: biased a touch upward so
        // there is headroom rather than a chest shot.
        let midX = rect.midX + shiftX
        let midY = rect.midY - (height - rect.height) * 0.06
        self.cardRect = rect
        self.cardRadius = cardRadius
        self.visibleRect = visible.isNull ? rect : visible
        self.scale = scale
        self.cameraRect = CGRect(x: midX - width / 2, y: midY - height / 2, width: width, height: height)
    }

    /// Width ÷ height of what shows on screen, the live bubble's aspect.
    var visibleAspect: CGFloat { visibleRect.width / max(visibleRect.height, 1) }

    /// The capture is always a centred 16:9 crop (`ScreenRecorder.sourceRect`)
    /// and every Studio number is proportional, so a 1920x1080 reference
    /// gives the same shapes as the real 1080p, 1440p or 4K export.
    static let referenceSize = CGSize(width: 1920, height: 1080)

    static func reference(face: FaceLayout, background: StudioBackground, cameraSize: CGSize) -> FaceCardFraming? {
        let geo = StudioGeometry(size: referenceSize, screenAspect: 16.0 / 9.0, face: face, background: background)
        return FaceCardFraming(geometry: geo, cameraSize: cameraSize)
    }

    /// The same framing mapped into a view of `bounds` that shows exactly
    /// `visibleRect` (the live bubble). Origin bottom-left, like a layer-
    /// backed NSView. Returns where the whole camera frame goes and the card
    /// outline to mask it with (it may run past the bounds; the view clips).
    func mapped(into bounds: CGRect) -> (camera: CGRect, card: CGPath) {
        let k = bounds.width / max(visibleRect.width, 1)
        let map = CGAffineTransform(translationX: bounds.minX, y: bounds.minY)
            .scaledBy(x: k, y: k)
            .translatedBy(x: -visibleRect.minX, y: -visibleRect.minY)
        let card = cardRect.applying(map)
        let radius = cardRadius * k
        return (
            cameraRect.applying(map),
            CGPath(roundedRect: card, cornerWidth: radius, cornerHeight: radius, transform: nil)
        )
    }
}

/// The camera at one instant.
struct StudioCamera {
    /// Screen pixels → output pixels.
    let screenToOutput: CGAffineTransform
    /// Overview canvas → output (identity at overview).
    let canvasToOutput: CGAffineTransform
    /// Output pixels per screen pixel, relative to the screen exactly filling
    /// the frame. ~0.78 to 0.92 at overview, 2 at a 2x zoom.
    let relativeScale: CGFloat

    /// Push-in toward the focus. The overview (a region of the screen shown
    /// in `overview`) and the zoomed view are joined by scaling about their
    /// common fixed point with a geometric (log-space) scale, so a push-in
    /// reads as one straight camera move rather than a slide plus a zoom.
    static func at(
        _ state: ZoomTimeline.State,
        geometry geo: StudioGeometry,
        screenSize: CGSize,
        region: CGRect = FocusPath.full,
        overview window: CGRect? = nil
    ) -> StudioCamera {
        let W = geo.size.width, H = geo.size.height
        let sw = max(screenSize.width, 1), sh = max(screenSize.height, 1)
        let window = window ?? geo.windowRect
        // The framed part of the screen, in screen pixels.
        let src = CGRect(x: region.minX * sw, y: region.minY * sh, width: region.width * sw, height: region.height * sh)
        let k0 = window.width / max(src.width, 1)
        let overview = CGAffineTransform(
            a: k0, b: 0, c: 0, d: k0, tx: window.minX - k0 * src.minX, ty: window.minY - k0 * src.minY
        )
        let fullFrame = W / sw

        guard state.progress > 0.0005 else {
            return StudioCamera(
                screenToOutput: overview, canvasToOutput: .identity,
                relativeScale: k0 / fullFrame
            )
        }

        if geo.light {
            // Light presets: the window never leaves its
            // frame, no edge of it is ever cut by the video. The zoom happens
            // INSIDE the window: the screen content scales within the fixed,
            // rounded window. `scale` is relative to the window here.
            let z = max(state.scale, 1.02)
            let K1 = z * k0
            let focus = CGPoint(x: state.center.x * sw, y: state.center.y * sh)
            var off = CGPoint(x: window.midX - K1 * focus.x, y: window.midY - K1 * focus.y)
            off.x = clamp(off.x, low: window.maxX - K1 * src.maxX, high: window.minX - K1 * src.minX)
            off.y = clamp(off.y, low: window.maxY - K1 * src.maxY, high: window.minY - K1 * src.minY)
            let c = z
            let t1 = CGPoint(x: off.x - c * overview.tx, y: off.y - c * overview.ty)
            let p = min(max(state.progress, 0), 1)
            let fixed = CGPoint(x: t1.x / (1 - c), y: t1.y / (1 - c))
            let cp = pow(c, p)
            let inner = CGAffineTransform(a: cp, b: 0, c: 0, d: cp, tx: fixed.x * (1 - cp), ty: fixed.y * (1 - cp))
            let screenToOutput = overview.concatenating(inner)
            return StudioCamera(
                screenToOutput: screenToOutput, canvasToOutput: .identity,
                relativeScale: screenToOutput.a / fullFrame
            )
        }

        // Zoomed target: the focus centred in the safe area, clamped so the
        // framed region always covers the frame, and stays inside the rounded
        // corners, so neither a corner nor the edge can show at full zoom.
        let insetCanvas = geo.windowRadius * 0.30 + geo.edgeWidth + 2
        let e = insetCanvas / k0
        let fills = max(W / max(src.width - 2 * e, 1), H / max(src.height - 2 * e, 1))
        let K1 = max(max(state.scale, 1.02) * fullFrame, fills)
        let focus = CGPoint(x: state.center.x * sw, y: state.center.y * sh)
        var off = CGPoint(x: geo.safeArea.midX - K1 * focus.x, y: geo.safeArea.midY - K1 * focus.y)
        off.x = clamp(off.x, low: W - K1 * (src.maxX - e), high: -K1 * (src.minX + e))
        off.y = clamp(off.y, low: H - K1 * (src.maxY - e), high: -K1 * (src.minY + e))

        // canvas → output at full zoom: out = c * canvas + t1
        let c = K1 / k0
        let t1 = CGPoint(x: off.x - c * overview.tx, y: off.y - c * overview.ty)

        let p = min(max(state.progress, 0), 1)
        let camera: CGAffineTransform
        if abs(c - 1) < 0.001 {
            camera = CGAffineTransform(translationX: t1.x * p, y: t1.y * p)
        } else {
            let fixed = CGPoint(x: t1.x / (1 - c), y: t1.y / (1 - c))
            let cp = pow(c, p)
            camera = CGAffineTransform(
                a: cp, b: 0, c: 0, d: cp,
                tx: fixed.x * (1 - cp), ty: fixed.y * (1 - cp)
            )
        }
        let screenToOutput = overview.concatenating(camera)
        return StudioCamera(
            screenToOutput: screenToOutput,
            canvasToOutput: camera,
            relativeScale: screenToOutput.a / fullFrame
        )
    }

    private static func clamp(_ v: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
        guard low <= high else { return (low + high) / 2 }
        return min(max(v, low), high)
    }
}

// MARK: - Renderer

/// Draws the Studio layout. One per export; every static piece (the room,
/// shadows, card edge, cursor) is built once and reused for every frame.
final class StudioRenderer {

    let geometry: StudioGeometry
    private let screenSize: CGSize

    private let room: CIImage
    private let windowShadow: CIImage
    private let cardShadow: CIImage
    private let cardMask: CIImage
    private let cardEdge: CIImage
    /// Arrow, I-beam and pointing hand, each with its hotspot and its
    /// reference height (the arrow's), so all three draw at one scale.
    private let sprites: [CursorShape: CursorSprite]
    private let ripple: CIImage
    /// Dynamic layout: each state's card shadow, baked the first time that
    /// state is drawn (a big card casts a bigger, softer shadow than a
    /// stretched small one would). Only touched from the compositor's
    /// serial render queue.
    private var stateCardShadows: [LayoutState: CIImage] = [:]
    private var stateWindowShadows: [LayoutState: CIImage] = [:]

    struct CursorSprite {
        let image: CIImage
        /// Hotspot inside the sprite, in sprite pixels.
        let hotspot: CGPoint
        /// Sprite pixels per design unit.
        let unit: CGFloat
    }

    /// Arrow height as a share of frame height when the screen fills the frame.
    /// About 1.8x the macOS default at this capture size.
    static let cursorHeight: CGFloat = 0.046
    /// The arrow's height in design units (all three sprites share units).
    static let arrowUnits: CGFloat = 19.3
    static let rippleDuration: Double = 0.55
    static let squishDuration: Double = 0.20

    init(renderSize: CGSize, screenSize: CGSize, face: FaceLayout, background: StudioBackground = .darkRoom) {
        let geo = StudioGeometry(
            size: renderSize,
            screenAspect: screenSize.width / max(screenSize.height, 1),
            face: face,
            background: background
        )
        self.geometry = geo
        self.screenSize = screenSize
        room = background.isLight
            ? StudioBackdrop.makeLightPlate(background, size: renderSize)
            : Self.makeRoom(geometry: geo)
        windowShadow = Self.makeShadow(
            size: renderSize, rect: geo.windowRect, radius: geo.windowRadius, heavy: true, light: geo.light, tall: false
        )
        // The shadow is cast by the card plus its rim.
        let rimRect = geo.cardRect.insetBy(dx: -geo.cardRim, dy: -geo.cardRim)
        cardShadow = Self.makeShadow(
            size: renderSize, rect: rimRect, radius: geo.cardRadius + geo.cardRim,
            heavy: false, light: geo.light, tall: face == .tallLeft
        )
        cardMask = ShapeMasking.alphaMask(
            size: renderSize,
            path: CGPath(
                roundedRect: geo.cardRect,
                cornerWidth: geo.cardRadius, cornerHeight: geo.cardRadius, transform: nil
            )
        )
        cardEdge = geo.light
            ? Self.makeRim(size: renderSize, rect: geo.cardRect, radius: geo.cardRadius, rim: geo.cardRim,
                           alpha: face == .tallLeft ? 0.9 : 1)
            : Self.makeEdge(size: renderSize, rect: geo.cardRect, radius: geo.cardRadius, width: geo.edgeWidth)
        sprites = [
            .arrow: Self.makeCursor(.arrow),
            .iBeam: Self.makeCursor(.iBeam),
            .hand: Self.makeCursor(.hand)
        ]
        ripple = Self.makeRipple()
    }

    // MARK: Per frame

    /// The window/card frame for one instant of the layout timeline. Nil =
    /// fixed layout (today's behaviour, byte for byte).
    func layoutFrame(for blend: LayoutBlend?) -> StudioLayoutFrame? {
        guard let blend else { return nil }
        let a = geometry.layoutFrame(blend.from)
        if blend.from == blend.to || blend.t >= 1 { return geometry.layoutFrame(blend.to) }
        if blend.t <= 0 { return a }
        return StudioLayoutFrame.lerp(a, geometry.layoutFrame(blend.to), blend.t)
    }

    /// Room, framed screen, cursor and click halos. The face card is drawn
    /// separately (`drawCard`) so the phone panel can sit between them.
    /// - Parameter region: the part of the screen the overview frames
    ///   (`FocusPath.full` = all of it; a focused app window otherwise).
    /// - Parameter layout: the dynamic layout at this instant; nil = fixed.
    func drawBase(
        screen: CIImage,
        time: Double,
        zoom: ZoomTimeline.State,
        region: CGRect = FocusPath.full,
        pointer: PointerPath?,
        clicks: [ClickTracker.Click],
        showClicks: Bool,
        layout: LayoutBlend? = nil
    ) -> CIImage {
        let size = geometry.size
        let frameRect = CGRect(origin: .zero, size: size)
        let dynamic = layoutFrame(for: layout).flatMap { $0 == geometry.fixedFrame ? nil : $0 }
        let windowRadius = dynamic?.windowRadius ?? geometry.windowRadius
        let overviewRect = geometry.overviewRect(
            for: region, screenAspect: screenSize.width / max(screenSize.height, 1),
            window: dynamic?.windowRect
        )
        // A zoom is relative to the window. When the window has grown (FOCUS)
        // the magnification on screen is held where the fixed layout puts it:
        // the bigger window shows more context, it does not zoom harder.
        var zoom = zoom
        if let dynamic, zoom.progress > 0, dynamic.windowRect.width > 1 {
            let k = geometry.windowRect.width / dynamic.windowRect.width
            zoom = ZoomTimeline.State(progress: zoom.progress, scale: max(1.02, zoom.scale * k), center: zoom.center)
        }
        let camera = StudioCamera.at(
            zoom, geometry: geometry, screenSize: screenSize, region: region, overview: overviewRect
        )
        let windowOut = overviewRect.applying(camera.canvasToOutput)
        let covers = windowOut.insetBy(dx: 1, dy: 1).contains(frameRect)
        let scaleNow = camera.canvasToOutput.a

        var out: CIImage
        if covers {
            out = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: frameRect)
        } else {
            // The room drifts ~1% so it never looks frozen, and pushes in a
            // little with the camera, that parallax is what makes it filmed.
            let push = geometry.light ? 1 : 1 + 0.07 * zoom.progress
            let drift = CGPoint(
                x: 0.006 * size.width * CGFloat(sin(time * 2 * .pi / 29)),
                y: 0.005 * size.height * CGFloat(sin(time * 2 * .pi / 37 + 1.3))
            )
            let roomTransform = CGAffineTransform(translationX: size.width / 2 + drift.x, y: size.height / 2 + drift.y)
                .scaledBy(x: push, y: push)
                .translatedBy(x: -size.width / 2, y: -size.height / 2)
            out = room.transformed(by: roomTransform).cropped(to: frameRect)
            // The baked shadow belongs to `windowRect`; a framed app window
            // borrows it, stretched onto its own rect.
            func stretched(_ shadow: CIImage, from base: CGRect) -> CIImage {
                if base == overviewRect, camera.canvasToOutput.isIdentity { return shadow }
                let stretch = CGAffineTransform(translationX: -base.minX, y: -base.minY)
                    .concatenating(CGAffineTransform(
                        scaleX: overviewRect.width / base.width, y: overviewRect.height / base.height
                    ))
                    .concatenating(CGAffineTransform(translationX: overviewRect.minX, y: overviewRect.minY))
                return shadow.transformed(by: stretch.concatenating(camera.canvasToOutput))
            }
            if dynamic != nil, let layout {
                // Dynamic layout: each state's own window shadow, cross-faded.
                let t = layout.from == layout.to ? 1 : min(max(layout.t, 0), 1)
                for (state, weight) in [(layout.from, 1 - t), (layout.to, t)] where weight > 0.001 {
                    var image = stretched(windowShadow(for: state), from: geometry.layoutFrame(state).windowRect)
                    if weight < 0.999 {
                        image = image.applyingFilter("CIColorMatrix", parameters: [
                            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: weight)
                        ])
                    }
                    out = image.composited(over: out)
                }
            } else {
                out = stretched(windowShadow, from: geometry.windowRect).composited(over: out)
            }
        }

        // The screen, in one transform from source pixels, never resampled twice.
        var placed = screen.transformed(
            by: camera.screenToOutput,
            highQualityDownsample: camera.screenToOutput.a < 1
        )
        if !covers {
            let radius = windowRadius * scaleNow
            let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                "inputExtent": CIVector(cgRect: windowOut),
                "inputRadius": radius,
                "inputColor": CIColor(red: 1, green: 1, blue: 1)
            ])?.outputImage ?? CIImage.empty()
            placed = placed.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: mask
            ])
        }
        out = placed.cropped(to: frameRect).composited(over: out)

        if !covers {
            out = windowEdge(rect: windowOut, radius: windowRadius * scaleNow, width: geometry.edgeWidth)
                .composited(over: out)
        }

        // Cursor sits on the screen, under the face card.
        let arrowHeight = Self.cursorHeight * size.height * sqrt(max(camera.relativeScale, 0.3))
        let toOutput = { (x: Double, y: Double) -> CGPoint in
            CGPoint(x: x * self.screenSize.width, y: y * self.screenSize.height)
                .applying(camera.screenToOutput)
        }

        if showClicks {
            for click in clicks {
                let age = time - click.time
                guard age >= 0, age <= Self.rippleDuration else { continue }
                let u = age / Self.rippleDuration
                let grow = 1 - pow(1 - u, 3)
                let radius = arrowHeight * CGFloat(0.45 + 0.85 * grow)
                let alpha = CGFloat(0.75 * pow(1 - u, 1.4))
                let center = toOutput(click.x, click.y)
                if !covers, !windowOut.contains(center) { continue }
                let s = radius * 2 / ripple.extent.width
                let halo = ripple
                    .transformed(by: CGAffineTransform(scaleX: s, y: s))
                    .transformed(by: CGAffineTransform(translationX: center.x - radius, y: center.y - radius))
                    .applyingFilter("CIColorMatrix", parameters: [
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)
                    ])
                out = halo.composited(over: out)
            }
        }

        if let pointer, let p = pointer.position(at: time),
           p.x >= -0.005, p.x <= 1.005, p.y >= -0.005, p.y <= 1.005 {
            // A framed app window hides the rest of the screen: no cursor
            // floating over the background outside it.
            let visible = covers || windowOut.insetBy(dx: -2, dy: -2).contains(toOutput(Double(p.x), Double(p.y)))
            if visible {
                out = drawCursorOnly(
                    at: toOutput(Double(p.x), Double(p.y)),
                    shape: pointer.shape(at: time),
                    relativeScale: camera.relativeScale,
                    clicks: clicks, time: time, over: out
                )
            }
        }

        return out.cropped(to: frameRect)
    }

    /// Our cursor with its hotspot at `tipOut` (output pixels). Grows gently
    /// with the zoom (square root), so it stays a cursor rather than a prop.
    func drawCursorOnly(
        at tipOut: CGPoint,
        shape: CursorShape = .arrow,
        relativeScale: CGFloat,
        clicks: [ClickTracker.Click],
        time: Double,
        over base: CIImage
    ) -> CIImage {
        // A small squish on each click, then back.
        var squish: CGFloat = 1
        for click in clicks {
            let age = time - click.time
            if age >= -0.04, age <= Self.squishDuration {
                let u = max(0, age + 0.04) / (Self.squishDuration + 0.04)
                squish = min(squish, 1 - 0.16 * CGFloat(sin(u * .pi)))
            }
        }
        guard let sprite = sprites[shape] ?? sprites[.arrow] else { return base }
        let arrowHeight = Self.cursorHeight * geometry.size.height * sqrt(max(relativeScale, 0.3))
        let scale = arrowHeight * squish / (Self.arrowUnits * sprite.unit)
        let image = sprite.image.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: scale,
            kCIInputAspectRatioKey: 1.0
        ])
        let hot = CGPoint(x: sprite.hotspot.x * scale, y: sprite.hotspot.y * scale)
        return image
            .transformed(by: CGAffineTransform(translationX: tipOut.x - hot.x, y: tipOut.y - hot.y))
            .composited(over: base)
            .cropped(to: base.extent)
    }

    /// The face card: shadow, graded camera cut to the card, glass edge.
    /// - Parameter layout: the dynamic layout at this instant; nil = fixed.
    func drawCard(
        camera: CIImage, alpha: CGFloat, grade: Bool, over base: CIImage, layout: LayoutBlend? = nil
    ) -> CIImage {
        if let layout, let frame = layoutFrame(for: layout), frame != geometry.fixedFrame {
            return drawMovingCard(camera: camera, alpha: alpha, grade: grade, over: base, frame: frame, blend: layout)
        }
        var source = camera
        if grade { source = Self.grade(source, light: geometry.light) }

        let rect = geometry.cardRect
        let extent = source.extent
        guard let framing = FaceCardFraming(geometry: geometry, cameraSize: extent.size) else { return base }
        // The crop itself lives in `FaceCardFraming`, the live camera bubble
        // uses the very same numbers, so what you see is what gets exported.
        var placed = source.transformed(
            by: CGAffineTransform(scaleX: framing.scale, y: framing.scale), highQualityDownsample: true
        )
        let dx = framing.cameraRect.midX - placed.extent.midX
        let dy = framing.cameraRect.midY - placed.extent.midY
        placed = placed.transformed(by: CGAffineTransform(translationX: dx, y: dy)).cropped(to: rect)
        placed = placed.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: cardMask
        ])

        var card = cardShadow
        card = placed.composited(over: card)
        card = cardEdge.composited(over: card)
        if alpha < 0.999 {
            card = card.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)
            ])
        }
        return card.composited(over: base).cropped(to: base.extent)
    }

    /// The face card anywhere other than its fixed slot: a dynamic-layout
    /// state or a frame of a morph. Same crop definition (`FaceCardFraming`),
    /// same grade; the mask and rim are generated for the current rect, and
    /// the shadow cross-fades between the two states' own baked shadows,
    /// each stretched onto the current rect.
    private func drawMovingCard(
        camera: CIImage, alpha: CGFloat, grade: Bool, over base: CIImage,
        frame: StudioLayoutFrame, blend: LayoutBlend
    ) -> CIImage {
        var source = camera
        if grade { source = Self.grade(source, light: geometry.light) }
        let rect = frame.cardRect
        guard let framing = FaceCardFraming(
            cardRect: rect, cardRadius: frame.cardRadius, frameSize: geometry.size, cameraSize: source.extent.size
        ) else { return base }

        var placed = source.transformed(
            by: CGAffineTransform(scaleX: framing.scale, y: framing.scale), highQualityDownsample: framing.scale < 1
        )
        let dx = framing.cameraRect.midX - placed.extent.midX
        let dy = framing.cameraRect.midY - placed.extent.midY
        placed = placed.transformed(by: CGAffineTransform(translationX: dx, y: dy)).cropped(to: rect)
        placed = placed.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: Self.roundedRect(rect, radius: frame.cardRadius, color: CIColor(red: 1, green: 1, blue: 1))
        ])

        // Shadow: each state's own, stretched from its rect onto this one.
        let rimRect = rect.insetBy(dx: -frame.cardRim, dy: -frame.cardRim)
        func shadow(_ state: LayoutState, weight: CGFloat) -> CIImage {
            guard weight > 0.001 else { return .empty() }
            let own = geometry.layoutFrame(state)
            let ownRim = own.cardRect.insetBy(dx: -own.cardRim, dy: -own.cardRim)
            var image = cardShadow(for: state)
            if ownRim != rimRect {
                image = image.transformed(by: CGAffineTransform(translationX: -ownRim.minX, y: -ownRim.minY)
                    .concatenating(CGAffineTransform(
                        scaleX: rimRect.width / max(ownRim.width, 1), y: rimRect.height / max(ownRim.height, 1)
                    ))
                    .concatenating(CGAffineTransform(translationX: rimRect.minX, y: rimRect.minY)))
            }
            if weight < 0.999 {
                image = image.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: weight)
                ])
            }
            return image
        }
        let t = blend.from == blend.to ? 1 : min(max(blend.t, 0), 1)
        var card = shadow(blend.from, weight: 1 - t).composited(over: shadow(blend.to, weight: t))
        card = placed.composited(over: card)
        if geometry.light, frame.cardRim > 0.1 {
            // The cream rim, a ring all round: outer rounded rect minus the card.
            let rimColor = CIColor(red: 0xFB / 255.0, green: 0xF6 / 255.0, blue: 0xEE / 255.0,
                                   alpha: geometry.face == .tallLeft ? 0.9 : 1)
            let ring = Self.roundedRect(rimRect, radius: frame.cardRadius + frame.cardRim, color: rimColor)
                .applyingFilter("CISourceOutCompositing", parameters: [
                    kCIInputBackgroundImageKey: Self.roundedRect(
                        rect.insetBy(dx: 0.5, dy: 0.5), radius: frame.cardRadius, color: CIColor(red: 1, green: 1, blue: 1)
                    )
                ])
            card = ring.composited(over: card)
        }
        if alpha < 0.999 {
            card = card.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)
            ])
        }
        return card.composited(over: base).cropped(to: base.extent)
    }

    /// The window's shadow for one layout state, baked past the frame edge
    /// (see `cardShadow(for:)`). The fixed layout keeps its own bake.
    private func windowShadow(for state: LayoutState) -> CIImage {
        if let cached = stateWindowShadows[state] { return cached }
        let frame = geometry.layoutFrame(state)
        let reach = 0.25 * geometry.size.height
        let image = Self.makeShadow(
            size: geometry.size, rect: frame.windowRect, radius: frame.windowRadius,
            heavy: true, light: geometry.light, tall: false,
            bakeIn: frame.windowRect.insetBy(dx: -reach, dy: -reach).integral
        )
        stateWindowShadows[state] = image
        return image
    }

    /// The card shadow for one layout state, baked for the dynamic path.
    private func cardShadow(for state: LayoutState) -> CIImage {
        if let cached = stateCardShadows[state] { return cached }
        let frame = geometry.layoutFrame(state)
        let rimRect = frame.cardRect.insetBy(dx: -frame.cardRim, dy: -frame.cardRim)
        // SPLIT/FACE cards are big and close: they cast the window's deep
        // shadow. SCREEN and FOCUS are the small card's own shadow.
        // Baked around the shadow itself, past the frame edge: this image is
        // stretched onto smaller rects mid-morph, and a frame-cropped bake
        // would carry that crop line along as a hard edge.
        let reach = 0.25 * geometry.size.height
        let image = Self.makeShadow(
            size: geometry.size, rect: rimRect, radius: frame.cardRadius + frame.cardRim,
            heavy: state == .split || state == .face, light: geometry.light, tall: geometry.face == .tallLeft,
            bakeIn: rimRect.insetBy(dx: -reach, dy: -reach).integral
        )
        stateCardShadows[state] = image
        return image
    }

    /// Plan §4 camera grade: about -0.3 EV, warmer (~700K: the plan's 400K moved a
    /// grey by only 3 levels, invisible on a cool wall), a touch more
    /// contrast, so a bright wall stops blowing out and the face sits in the
    /// same warm world as the room.
    /// On a light background the face sits next to cream, not a dark room:
    /// a gentler pull-down (the mockups use the camera nearly as shot, with a
    /// touch of warmth) so the face does not read muddy against the paper.
    static func grade(_ image: CIImage, light: Bool = false) -> CIImage {
        image
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: light ? -0.12 : -0.3])
            .applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 5800, y: 0)
            ])
            .applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1.06,
                kCIInputSaturationKey: 1.03,
                kCIInputBrightnessKey: 0.0
            ])
    }

    /// The window's edge. Dark room: luminous cream glass, brighter on top.
    /// Light presets: the mockup's thin white inner line at 55%.
    private func windowEdge(rect: CGRect, radius: CGFloat, width: CGFloat) -> CIImage {
        if geometry.light {
            let inset = rect.insetBy(dx: width / 2, dy: width / 2)
            return CIFilter(name: "CIRoundedRectangleStrokeGenerator", parameters: [
                "inputExtent": CIVector(cgRect: inset),
                "inputRadius": max(radius - width / 2, 0),
                "inputWidth": width,
                "inputColor": CIColor(red: 1, green: 1, blue: 1, alpha: 0.55)
            ])?.outputImage ?? .empty()
        }
        guard let stroke = CIFilter(name: "CIRoundedRectangleStrokeGenerator", parameters: [
            "inputExtent": CIVector(cgRect: rect),
            "inputRadius": radius,
            "inputWidth": width,
            "inputColor": CIColor(
                red: StudioPalette.cream[0], green: StudioPalette.cream[1], blue: StudioPalette.cream[2]
            )
        ])?.outputImage else { return .empty() }
        let top = min(rect.maxY, geometry.size.height)
        let gradient = CIFilter(name: "CISmoothLinearGradient", parameters: [
            "inputPoint0": CIVector(x: rect.midX, y: top),
            "inputPoint1": CIVector(x: rect.midX, y: top - geometry.size.height * 0.9),
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 0.62),
            "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 0.16)
        ])?.outputImage ?? CIImage.empty()
        return stroke.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: gradient
        ])
    }

    // MARK: - Static pieces (built once)

    private static func context(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: max(width, 1), height: max(height, 1),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private static func gradient(_ stops: [(CGFloat, [CGFloat], CGFloat)]) -> CGGradient {
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

    /// The lit dark room: chocolate core fading to near-black, a warm rose
    /// bloom behind the window, a faint diagonal beam, bokeh, vignette, grain.
    /// Built 10% oversize so the drift and the parallax push never show an edge.
    private static func makeRoom(geometry geo: StudioGeometry) -> CIImage {
        let over: CGFloat = 1.10
        let fw = geo.size.width, fh = geo.size.height
        let width = Int((fw * over).rounded()), height = Int((fh * over).rounded())
        let ox = (CGFloat(width) - fw) / 2, oy = (CGFloat(height) - fh) / 2
        guard let ctx = context(width: width, height: height) else { return .empty() }
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        let win = geo.windowRect.offsetBy(dx: ox, dy: oy)

        ctx.setFillColor(StudioPalette.cg(StudioPalette.ink))
        ctx.fill(full)

        // Chocolate core high in the frame, falling off to near-black.
        let core = CGPoint(x: ox + fw * 0.52, y: oy + fh * 0.96)
        ctx.drawRadialGradient(
            gradient([
                (0, StudioPalette.chocolateLift, 1),
                (0.30, StudioPalette.chocolate, 1),
                (0.75, StudioPalette.ink, 1)
            ]),
            startCenter: core, startRadius: 0, endCenter: core, endRadius: fw * 0.85,
            options: [.drawsAfterEndLocation]
        )

        // The window is lit from behind: a warm rose bloom hugging its top
        // edge, so the edge glows against the room instead of sitting on mud.
        let bloom = CGPoint(x: win.midX, y: min(win.maxY, oy + fh))
        ctx.saveGState()
        ctx.translateBy(x: bloom.x, y: bloom.y)
        ctx.scaleBy(x: 1, y: 0.42)
        ctx.drawRadialGradient(
            gradient([
                (0, StudioPalette.rose, 0.42),
                (0.35, StudioPalette.roseDeep, 0.20),
                (1, StudioPalette.rose, 0)
            ]),
            startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: fw * 0.52, options: []
        )
        ctx.restoreGState()
        // A second, smaller warm pool low on the other side, for depth.
        let pool = CGPoint(x: ox + fw * 0.06, y: oy + fh * 0.10)
        ctx.drawRadialGradient(
            gradient([(0, StudioPalette.sand, 0.06), (1, StudioPalette.sand, 0)]),
            startCenter: pool, startRadius: 0, endCenter: pool, endRadius: fw * 0.30, options: []
        )

        // Soft diagonal light beam from the top right, fading as it falls.
        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        let source = CGPoint(x: ox + fw * 0.86, y: oy + fh * 1.05)
        let target = CGPoint(x: ox + fw * 0.22, y: oy - fh * 0.1)
        let axis = CGVector(dx: target.x - source.x, dy: target.y - source.y)
        let length = hypot(axis.dx, axis.dy)
        let normal = CGVector(dx: -axis.dy / length, dy: axis.dx / length)
        let mid = CGPoint(x: (source.x + target.x) / 2, y: (source.y + target.y) / 2)
        let half = fw * 0.11
        ctx.drawLinearGradient(
            gradient([
                (0, StudioPalette.cream, 0),
                (0.30, StudioPalette.cream, 0.04),
                (0.5, StudioPalette.cream, 0.11),
                (0.70, StudioPalette.cream, 0.04),
                (1, StudioPalette.cream, 0)
            ]),
            start: CGPoint(x: mid.x - normal.dx * half, y: mid.y - normal.dy * half),
            end: CGPoint(x: mid.x + normal.dx * half, y: mid.y + normal.dy * half),
            options: []
        )
        ctx.setBlendMode(.destinationIn)
        ctx.drawRadialGradient(
            gradient([(0, StudioPalette.ink, 1), (0.55, StudioPalette.ink, 0.55), (1, StudioPalette.ink, 0)]),
            startCenter: source, startRadius: 0, endCenter: source, endRadius: length * 0.95,
            options: []
        )
        ctx.endTransparencyLayer()
        ctx.restoreGState()

        // Bokeh: a few soft out-of-focus orbs, seeded so renders repeat exactly.
        var rng = SeededRandom(seed: 0x5EED_2026)
        for i in 0..<10 {
            let x = ox + fw * CGFloat(rng.next())
            // Most in the upper margin and the sides, where the room shows.
            let y = oy + fh * (i % 3 == 0 ? CGFloat(rng.next()) : 0.80 + 0.2 * CGFloat(rng.next()))
            let r = fw * (0.018 + 0.05 * CGFloat(rng.next()))
            let color = i % 2 == 0 ? StudioPalette.rose : StudioPalette.cream
            let alpha = 0.035 + 0.05 * CGFloat(rng.next())
            let c = CGPoint(x: x, y: y)
            ctx.drawRadialGradient(
                gradient([(0, color, alpha), (0.6, color, alpha * 0.7), (1, color, 0)]),
                startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: []
            )
        }

        // Vignette.
        let centre = CGPoint(x: ox + fw / 2, y: oy + fh / 2)
        let diag = hypot(fw, fh) / 2
        ctx.drawRadialGradient(
            gradient([(0, StudioPalette.ink, 0), (0.55, StudioPalette.ink, 0), (1, StudioPalette.ink, 0.70)]),
            startCenter: centre, startRadius: 0, endCenter: centre, endRadius: diag * 1.12,
            options: [.drawsAfterEndLocation]
        )

        // Grain: also dithers the dark gradients so H.264 cannot band them.
        if let data = ctx.data {
            let bytes = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * height)
            var noise = SeededRandom(seed: 0x6A1A)
            for row in 0..<height {
                let base = row * ctx.bytesPerRow
                for col in 0..<width {
                    let n = Int((noise.next() - 0.5) * 7)
                    let p = base + col * 4
                    for ch in 0..<3 {
                        bytes[p + ch] = UInt8(clamping: Int(bytes[p + ch]) + n)
                    }
                }
            }
        }

        guard let image = ctx.makeImage() else { return .empty() }
        return GPUResident.image(image).transformed(by: CGAffineTransform(translationX: -ox, y: -oy))
    }

    /// Float context for baking the static pieces once. Shadows are long, faint
    /// gradients: baked at 8 bits they band into visible concentric rings over
    /// dark content, so they are rendered and kept at half-float.
    private static let baker = CIContext(options: [
        .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: false
    ])

    private static func bake(_ image: CIImage, in rect: CGRect) -> CIImage {
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let cg = baker.createCGImage(image, from: rect, format: .RGBAh, colorSpace: space) else {
            return image.cropped(to: rect)
        }
        return GPUResident.image(cg).transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }

    private static func roundedRect(_ rect: CGRect, radius: CGFloat, color: CIColor) -> CIImage {
        CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: rect),
            "inputRadius": radius,
            "inputColor": color
        ])?.outputImage ?? .empty()
    }

    /// Soft deep shadow (a wide one plus a tight contact one) and, for the
    /// dark window, a faint warm bloom. The rect itself is filled room-dark, so
    /// any anti-aliasing fringe of whatever sits on top reads dark, never light.
    /// No light outer glow: a blurred cream fringe reads as a second outline.
    ///
    /// Light presets use the mockup's warm brown shadows instead of black:
    /// window `0 50px 110px rgba(92,50,28,.30), 0 16px 34px rgba(92,50,28,.18)`,
    /// card `0 28px 60px rgba(92,50,28,.32)` (CSS blur N = Gaussian sigma N/2).
    private static func makeShadow(
        size: CGSize, rect: CGRect, radius: CGFloat, heavy: Bool, light: Bool, tall: Bool,
        bakeIn: CGRect? = nil
    ) -> CIImage {
        let H = size.height
        func soft(_ color: CIColor, sigma: CGFloat, dy: CGFloat, grow: CGFloat = 0) -> CIImage {
            roundedRect(rect.insetBy(dx: -grow, dy: -grow), radius: radius + grow, color: color)
                .applyingGaussianBlur(sigma: sigma)
                .transformed(by: CGAffineTransform(translationX: 0, y: dy))
        }
        let rose = StudioPalette.rose
        var layers: [CIImage] = []
        if light {
            let u = H / 1080
            let brown = (r: 92.0 / 255, g: 50.0 / 255, b: 28.0 / 255)
            func warm(_ a: CGFloat) -> CIColor { CIColor(red: brown.r, green: brown.g, blue: brown.b, alpha: a) }
            if heavy {
                layers.append(soft(warm(0.30), sigma: 55 * u, dy: -50 * u))
                layers.append(soft(warm(0.18), sigma: 17 * u, dy: -16 * u))
            } else if tall {
                layers.append(soft(warm(0.30), sigma: 35 * u, dy: -30 * u))   // 0 30px 70px
            } else {
                layers.append(soft(warm(0.32), sigma: 30 * u, dy: -28 * u))   // 0 28px 60px
            }
        } else if heavy {
            layers.append(soft(CIColor(red: rose[0], green: rose[1], blue: rose[2], alpha: 0.13),
                               sigma: 0.075 * H, dy: 0, grow: 0.01 * H))
            layers.append(soft(CIColor(red: 0, green: 0, blue: 0, alpha: 0.62), sigma: 0.042 * H, dy: -0.030 * H))
            layers.append(soft(CIColor(red: 0, green: 0, blue: 0, alpha: 0.45), sigma: 0.008 * H, dy: -0.005 * H))
        } else {
            layers.append(soft(CIColor(red: 0, green: 0, blue: 0, alpha: 0.55), sigma: 0.022 * H, dy: -0.012 * H))
            layers.append(soft(CIColor(red: 0, green: 0, blue: 0, alpha: 0.40), sigma: 0.005 * H, dy: -0.003 * H))
        }
        // Under a light card the rim covers this; under the window it only
        // ever shows as a hairline, which reads as the screen's own edge.
        let ink = light ? StudioPalette.chocolate : StudioPalette.ink
        layers.append(roundedRect(rect, radius: radius, color: CIColor(red: ink[0], green: ink[1], blue: ink[2])))

        var image = CIImage.empty()
        for layer in layers { image = layer.composited(over: image) }
        return bake(image, in: bakeIn ?? CGRect(origin: .zero, size: size))
    }

    /// Light presets: the face card's cream rim, a ring all round (mockup
    /// `0 0 0 5px #FBF6EE`; tall card 4px at 90%).
    private static func makeRim(size: CGSize, rect: CGRect, radius: CGFloat, rim: CGFloat, alpha: CGFloat) -> CIImage {
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        guard let ctx = context(width: w, height: h) else { return .empty() }
        let outer = rect.insetBy(dx: -rim, dy: -rim)
        ctx.addPath(CGPath(roundedRect: outer, cornerWidth: radius + rim, cornerHeight: radius + rim, transform: nil))
        ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(CGColor(srgbRed: 0xFB / 255.0, green: 0xF6 / 255.0, blue: 0xEE / 255.0, alpha: alpha))
        ctx.fillPath(using: .evenOdd)
        guard let image = ctx.makeImage() else { return .empty() }
        return GPUResident.image(image)
    }

    /// Static glass edge for the face card (it never moves, so it is drawn
    /// once, crisp, with the same top-bright gradient as the window edge).
    private static func makeEdge(size: CGSize, rect: CGRect, radius: CGFloat, width: CGFloat) -> CIImage {
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        guard let ctx = context(width: w, height: h) else { return .empty() }
        let inset = rect.insetBy(dx: width / 2, dy: width / 2)
        ctx.addPath(CGPath(
            roundedRect: inset, cornerWidth: max(radius - width / 2, 0),
            cornerHeight: max(radius - width / 2, 0), transform: nil
        ))
        ctx.setLineWidth(width * 1.15)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(
            gradient([(0, StudioPalette.cream, 0.70), (0.5, StudioPalette.cream, 0.34), (1, StudioPalette.cream, 0.14)]),
            start: CGPoint(x: rect.midX, y: rect.maxY),
            end: CGPoint(x: rect.midX, y: rect.minY),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        guard let image = ctx.makeImage() else { return .empty() }
        return GPUResident.image(image)
    }

    /// Design paths, y-down, hotspot at (0, 0), in the arrow's units (the
    /// arrow is 19.3 tall). Same material for all three: cream body,
    /// chocolate outline, soft shadow, the macOS shapes, in brand colours.
    private static func cursorPath(_ shape: CursorShape) -> (body: CGPath, detail: CGPath?) {
        switch shape {
        case .iBeam:
            // Hotspot in the middle of the bar, like the system I-beam.
            let skeleton = CGMutablePath()
            skeleton.move(to: CGPoint(x: 0, y: -7.7))
            skeleton.addLine(to: CGPoint(x: 0, y: 7.7))
            for sign in [-1.0, 1.0] as [CGFloat] {
                skeleton.move(to: CGPoint(x: -2.8, y: 9.0 * sign))
                skeleton.addQuadCurve(to: CGPoint(x: 0, y: 7.7 * sign), control: CGPoint(x: -0.4, y: 9.0 * sign))
                skeleton.addQuadCurve(to: CGPoint(x: 2.8, y: 9.0 * sign), control: CGPoint(x: 0.4, y: 9.0 * sign))
            }
            return (skeleton.copy(strokingWithWidth: 1.35, lineCap: .round, lineJoin: .round, miterLimit: 4), nil)

        case .hand:
            // Pointing hand, hotspot at the tip of the index finger.
            let p = CGMutablePath()
            p.move(to: CGPoint(x: -1.65, y: 1.65))
            p.addArc(center: CGPoint(x: 0, y: 1.65), radius: 1.65, startAngle: .pi, endAngle: 0, clockwise: false)
            p.addLine(to: CGPoint(x: 1.65, y: 8.6))
            p.addArc(center: CGPoint(x: 2.7, y: 8.6), radius: 1.05, startAngle: .pi, endAngle: 0, clockwise: false)
            p.addLine(to: CGPoint(x: 3.75, y: 9.4))
            p.addArc(center: CGPoint(x: 4.7, y: 9.4), radius: 0.95, startAngle: .pi, endAngle: 0, clockwise: false)
            p.addLine(to: CGPoint(x: 5.65, y: 10.3))
            p.addArc(center: CGPoint(x: 6.5, y: 10.3), radius: 0.85, startAngle: .pi, endAngle: 0, clockwise: false)
            p.addLine(to: CGPoint(x: 7.35, y: 15.2))
            p.addQuadCurve(to: CGPoint(x: 4.4, y: 20.4), control: CGPoint(x: 7.35, y: 19.6))
            p.addLine(to: CGPoint(x: -1.2, y: 20.4))
            p.addQuadCurve(to: CGPoint(x: -4.1, y: 17.6), control: CGPoint(x: -3.6, y: 20.4))
            p.addQuadCurve(to: CGPoint(x: -7.1, y: 12.6), control: CGPoint(x: -5.9, y: 15.4))
            p.addQuadCurve(to: CGPoint(x: -5.3, y: 11.2), control: CGPoint(x: -7.5, y: 10.9))
            p.addLine(to: CGPoint(x: -1.65, y: 13.0))
            p.closeSubpath()
            let detail = CGMutablePath()
            detail.move(to: CGPoint(x: 1.65, y: 9.2)); detail.addLine(to: CGPoint(x: 1.65, y: 12.2))
            detail.move(to: CGPoint(x: 3.75, y: 10.0)); detail.addLine(to: CGPoint(x: 3.75, y: 12.6))
            detail.move(to: CGPoint(x: 5.65, y: 10.9)); detail.addLine(to: CGPoint(x: 5.65, y: 13.0))
            return (p, detail)

        case .arrow, .other:
            let p = CGMutablePath()
            p.addLines(between: [
                CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 16.9), CGPoint(x: 4.1, y: 13.2),
                CGPoint(x: 6.8, y: 19.3), CGPoint(x: 9.4, y: 18.2), CGPoint(x: 6.8, y: 12.3),
                CGPoint(x: 12.3, y: 12.3)
            ])
            p.closeSubpath()
            return (p, nil)
        }
    }

    /// One cursor sprite: drawn large once, scaled down per frame with Lanczos.
    private static func makeCursor(_ shape: CursorShape) -> CursorSprite {
        let unit: CGFloat = 14
        let pad: CGFloat = 70
        let (path, detail) = cursorPath(shape)
        let box = path.boundingBoxOfPath
        let width = Int((box.width * unit + pad * 2).rounded())
        let height = Int((box.height * unit + pad * 2).rounded())
        let hotspot = CGPoint(x: pad - box.minX * unit, y: CGFloat(height) - pad + box.minY * unit)
        guard let ctx = context(width: width, height: height) else {
            return CursorSprite(image: .empty(), hotspot: .zero, unit: unit)
        }
        // Design coordinates are y-down from the hotspot; flip into CG space.
        ctx.translateBy(x: hotspot.x, y: hotspot.y)
        ctx.scaleBy(x: unit, y: -unit)

        // Outline + shadow.
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0.5 * unit, height: -1.4 * unit),
            blur: 3.2 * unit,
            color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.55)
        )
        ctx.addPath(path)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(1.9)
        ctx.setStrokeColor(StudioPalette.cg(StudioPalette.chocolate))
        ctx.setFillColor(StudioPalette.cg(StudioPalette.chocolate))
        ctx.drawPath(using: .fillStroke)
        ctx.restoreGState()

        // Cream body, with a faint top-to-bottom warmth so it is not flat.
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.drawLinearGradient(
            gradient([(0, StudioPalette.cream, 1), (1, [0.925, 0.871, 0.776], 1)]),
            start: CGPoint(x: 0, y: box.minY), end: CGPoint(x: 0, y: box.maxY),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        ctx.restoreGState()

        if let detail {
            ctx.addPath(detail)
            ctx.setLineCap(.round)
            ctx.setLineWidth(0.55)
            ctx.setStrokeColor(StudioPalette.cg(StudioPalette.chocolate, 0.75))
            ctx.strokePath()
        }

        guard let image = ctx.makeImage() else { return CursorSprite(image: .empty(), hotspot: .zero, unit: unit) }
        return CursorSprite(image: CIImage(cgImage: image), hotspot: hotspot, unit: unit)
    }

    /// Soft rose halo: a gentle glow with a brighter rim, no hard ring.
    private static func makeRipple() -> CIImage {
        let side = 512
        guard let ctx = context(width: side, height: side) else { return .empty() }
        let c = CGPoint(x: side / 2, y: side / 2)
        ctx.drawRadialGradient(
            gradient([
                (0, StudioPalette.rose, 0),
                (0.55, StudioPalette.rose, 0.04),
                (0.82, StudioPalette.rose, 0.62),
                (0.91, StudioPalette.rose, 0.22),
                (1, StudioPalette.rose, 0)
            ]),
            startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(side) / 2, options: []
        )
        guard let image = ctx.makeImage() else { return .empty() }
        return CIImage(cgImage: image)
    }
}

/// Deterministic PRNG (SplitMix64) so the room renders identically every time.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}
