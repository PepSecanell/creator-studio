import AVFoundation
import CoreImage
import CoreGraphics
import Foundation

/// Everything the compositor needs to draw one take.
///
/// Carried on the instruction rather than held statically, because
/// AVFoundation instantiates the compositor class itself and gives us no
/// other way to hand it parameters.
final class CompositorSettings {
    var screenTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    var cameraTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    var phoneTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    /// Bubble position in render pixels, origin bottom-left.
    var bubbleRect: CGRect = .zero
    var bubbleCornerRadius: CGFloat = 0
    var bubbleShape: BubbleShape = .circle
    var bubbleTilt: CGFloat = 0

    /// Phone panel in render pixels, origin bottom-left.
    var phoneRect: CGRect = .zero
    var phoneCornerRadius: CGFloat = 0
    /// Draw the screen inside an iPhone-shaped body instead of a bare panel.
    var phoneShowsFrame = true

    var zoom: ZoomTimeline = .none
    var clicks: [ClickTracker.Click] = []
    var showClickHighlight = true
    var renderSize: CGSize = .zero

    /// Screen-share look. `.classic` is the original full-bleed
    /// screen with the dragged bubble, kept so nothing is lost.
    var layout: ScreenLayout = .classic
    /// Face card slot in the Studio layout. Ignored by `.classic`.
    var faceLayout: FaceLayout = .standard
    /// Warm, slightly darker camera grade on the face card (Studio only).
    var cameraGrade = true
    /// What the Studio layout sits on (six light presets + the dark room).
    var background: StudioBackground = .standard
    /// Non-nil = the overview frames the focused app window over time (A8).
    var focus: FocusPath?
    /// Studio only: when the layout moves between FACE / SPLIT / SCREEN /
    /// FOCUS. `.fixed` = one layout for the whole take (today's behaviour).
    var layoutTimeline: LayoutTimeline = .fixed
    /// Non-nil = draw our own smoothed cursor from this path. Only set when
    /// the system cursor was left out of the capture, or there would be two.
    var pointer: PointerPath?

    /// When each overlay was actually delivering frames. Empty means "always".
    ///
    /// Needed because AVFoundation keeps handing back a track's **last
    /// frame** outside its media rather than nothing at all. Unplug the
    /// iPhone mid-take and, without this, its panel freezes on that final
    /// frame for the rest of the video and looks like a glitch, and plug it
    /// in mid-take and its first frame would smear backwards over everything
    /// that came before.
    var cameraSegments: [ClipSegment] = []
    var phoneSegments: [ClipSegment] = []

    /// How long an overlay takes to fade as it joins or drops out.
    static let overlayFade: Double = 0.3
}

final class StudioInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    var timeRange: CMTimeRange
    var enablePostProcessing: Bool = false
    var containsTweening: Bool = true
    var requiredSourceTrackIDs: [NSValue]?
    var passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    let settings: CompositorSettings

    init(timeRange: CMTimeRange, settings: CompositorSettings) {
        self.timeRange = timeRange
        self.settings = settings
        var ids: [NSValue] = [NSNumber(value: settings.screenTrackID)]
        if settings.cameraTrackID != kCMPersistentTrackID_Invalid {
            ids.append(NSNumber(value: settings.cameraTrackID))
        }
        if settings.phoneTrackID != kCMPersistentTrackID_Invalid {
            ids.append(NSNumber(value: settings.phoneTrackID))
        }
        self.requiredSourceTrackIDs = ids
        super.init()
    }
}

/// Draws the finished frame: screen, then the click ring, then the phone
/// panel, then the camera bubble on top.
final class StudioCompositor: NSObject, AVVideoCompositing {

    /// How long a click ring lives, and how far it expands.
    private static let ringDuration: Double = 0.45
    private static let ringMaxRadius: CGFloat = 46
    /// Dusty rose, used instead of red for the recording cue.
    private static let ringColor = CIColor(red: 0.831, green: 0.643, blue: 0.604)

    var sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]
    ]

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]
    ]

    private var renderContext: AVVideoCompositionRenderContext?
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let renderQueue = DispatchQueue(label: "io.github.creatorstudio.recorder.compositor")

    private var maskCache: [String: CIImage] = [:]
    private var ringImage: CIImage?
    /// Built on the first Studio frame and reused; rebuilt only if the size
    /// or face slot changes.
    private var studio: StudioRenderer?

    // A dropped/non-monotonic screen sample during capture (ScreenRecorder.swift) leaves a genuine gap
    // in the screen track that sourceFrame(byTrackID:) reports as nil at export time. That used to fail
    // the whole mixdown for what is, on screen, a single missed frame, invisible if we just repeat the
    // last one instead. Only accessed from renderQueue, which is serial, so no locking needed.
    private var lastScreenBuffer: CVPixelBuffer?

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderQueue.sync {
            self.renderContext = newRenderContext
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async {
            self.render(request)
        }
    }

    // MARK: - Rendering

    private func render(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? StudioInstruction,
              let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: CompositorError.noRenderBuffer)
            return
        }

        let settings = instruction.settings
        let size = settings.renderSize
        let time = request.compositionTime.seconds

        guard let screenBuffer = request.sourceFrame(byTrackID: settings.screenTrackID) ?? lastScreenBuffer else {
            // No frame for this instant AND nothing to repeat yet, only reachable at the very start of
            // the take, which is a real problem rather than one dropped sample mid-recording.
            request.finish(with: CompositorError.missingScreenFrame)
            return
        }
        lastScreenBuffer = screenBuffer

        var frame = CIImage(cvPixelBuffer: screenBuffer)
        let zoom = settings.zoom.state(at: time)
        var studioLayer: StudioRenderer?
        let layout = settings.layout == .studio ? settings.layoutTimeline.blend(at: time) : nil

        if settings.layout == .studio {
            let renderer = studioRenderer(for: settings, screenSize: frame.extent.size)
            studioLayer = renderer
            frame = renderer.drawBase(
                screen: frame,
                time: time,
                zoom: zoom,
                region: settings.focus?.rect(at: time) ?? FocusPath.full,
                pointer: settings.pointer,
                clicks: settings.clicks,
                showClicks: settings.showClickHighlight,
                layout: layout
            )
        } else {
            // Click rings live in screen space, so they are drawn before the
            // zoom transform and get carried along by it.
            if settings.showClickHighlight {
                frame = applyClickRings(to: frame, settings: settings, time: time, size: size)
            }

            // Push in toward whatever was clicked.
            var transform = CGAffineTransform.identity
            let scale = zoom.blendedScale
            if scale > 1.001 {
                let focus = CGPoint(x: zoom.center.x * size.width, y: zoom.center.y * size.height)
                transform = CGAffineTransform(translationX: focus.x, y: focus.y)
                    .scaledBy(x: scale, y: scale)
                    .translatedBy(x: -focus.x, y: -focus.y)
                frame = frame.transformed(by: transform)
            }

            frame = frame.cropped(to: CGRect(origin: .zero, size: size))

            if let pointer = settings.pointer {
                frame = drawClassicCursor(pointer, over: frame, transform: transform, settings: settings, time: time)
            }
        }

        // Phone panel, then bubble on top.
        let phoneAlpha = settings.phoneSegments.overlayAlpha(
            at: time, fade: CompositorSettings.overlayFade
        )
        if settings.phoneTrackID != kCMPersistentTrackID_Invalid,
           phoneAlpha > 0.001,
           let phoneBuffer = request.sourceFrame(byTrackID: settings.phoneTrackID),
           !settings.phoneRect.isEmpty {
            let drawn = drawPhone(
                CIImage(cvPixelBuffer: phoneBuffer),
                over: frame,
                settings: settings
            )
            frame = phoneAlpha < 0.999
                ? blend(drawn, over: frame, alpha: phoneAlpha, bounds: CGRect(origin: .zero, size: size))
                : drawn
        }

        let cameraAlpha = settings.cameraSegments.overlayAlpha(
            at: time, fade: CompositorSettings.overlayFade
        )
        if settings.cameraTrackID != kCMPersistentTrackID_Invalid,
           cameraAlpha > 0.001,
           let cameraBuffer = request.sourceFrame(byTrackID: settings.cameraTrackID),
           let renderer = studioLayer {
            frame = renderer.drawCard(
                camera: CIImage(cvPixelBuffer: cameraBuffer),
                alpha: cameraAlpha,
                grade: settings.cameraGrade,
                over: frame,
                layout: layout
            )
        } else if settings.cameraTrackID != kCMPersistentTrackID_Invalid,
           cameraAlpha > 0.001,
           let cameraBuffer = request.sourceFrame(byTrackID: settings.cameraTrackID),
           !settings.bubbleRect.isEmpty {
            var bubble = fit(
                CIImage(cvPixelBuffer: cameraBuffer),
                into: settings.bubbleRect,
                mode: .fill,
                shape: settings.bubbleShape,
                tilt: settings.bubbleTilt
            )
            if cameraAlpha < 0.999 {
                bubble = bubble.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: cameraAlpha)
                ])
            }
            frame = bubble.composited(over: frame)
        }

        ciContext.render(
            frame,
            to: output,
            bounds: CGRect(origin: .zero, size: size),
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
        )
        request.finish(withComposedVideoFrame: output)
    }

    // MARK: - Studio

    private func studioRenderer(for settings: CompositorSettings, screenSize: CGSize) -> StudioRenderer {
        if let studio,
           studio.geometry.size == settings.renderSize,
           studio.geometry.face == settings.faceLayout,
           studio.geometry.background == settings.background {
            return studio
        }
        let renderer = StudioRenderer(
            renderSize: settings.renderSize, screenSize: screenSize,
            face: settings.faceLayout, background: settings.background
        )
        studio = renderer
        return renderer
    }

    /// Our cursor over the classic full-bleed layout: same sprite as Studio,
    /// placed through the classic zoom transform.
    private func drawClassicCursor(
        _ pointer: PointerPath,
        over frame: CIImage,
        transform: CGAffineTransform,
        settings: CompositorSettings,
        time: Double
    ) -> CIImage {
        guard let point = pointer.position(at: time),
              point.x >= -0.005, point.x <= 1.005, point.y >= -0.005, point.y <= 1.005 else { return frame }
        let renderer = studioRenderer(for: settings, screenSize: settings.renderSize)
        return renderer.drawCursorOnly(
            at: CGPoint(x: point.x * settings.renderSize.width, y: point.y * settings.renderSize.height)
                .applying(transform),
            shape: pointer.shape(at: time),
            relativeScale: transform.a,
            clicks: settings.clicks,
            time: time,
            over: frame
        )
    }

    // MARK: - Pieces

    /// Cross-fades a fully drawn layer over the frame it was drawn on.
    /// Used for the phone panel, whose body and screen are composited
    /// together before the fade applies.
    private func blend(
        _ top: CIImage, over bottom: CIImage, alpha: CGFloat, bounds: CGRect
    ) -> CIImage {
        let faded = top.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)
        ])
        return faded.composited(over: bottom).cropped(to: bounds)
    }

    private enum FitMode { case fit, fill }

    /// Scales an image into a rect and cuts it to an arbitrary shape.
    private func fit(
        _ image: CIImage,
        into rect: CGRect,
        mode: FitMode,
        shape: BubbleShape,
        tilt: CGFloat
    ) -> CIImage {
        let placed = place(image, into: rect, mode: mode)
        let mask = shapeMask(size: rect.size, shape: shape, tilt: tilt)
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
        return placed.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask
        ])
    }

    /// Scales an image into a rect and rounds its corners.
    private func fit(
        _ image: CIImage,
        into rect: CGRect,
        mode: FitMode,
        cornerRadius: CGFloat
    ) -> CIImage {
        let result = place(image, into: rect, mode: mode)

        guard cornerRadius > 0.5 else { return result }
        let mask = roundedMask(size: rect.size, cornerRadius: cornerRadius)
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))

        return result.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask
        ])
    }

    /// Scale-and-centre only, no masking.
    private func place(_ image: CIImage, into rect: CGRect, mode: FitMode) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return .empty() }

        let scaleX = rect.width / extent.width
        let scaleY = rect.height / extent.height
        let scale = mode == .fill ? max(scaleX, scaleY) : min(scaleX, scaleY)

        var result = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let scaled = result.extent

        let dx = rect.midX - scaled.midX
        let dy = rect.midY - scaled.midY
        result = result.transformed(by: CGAffineTransform(translationX: dx, y: dy))
        return result.cropped(to: rect)
    }

    /// Mask for any bubble shape, cached by shape and tilt. Building itself
    /// lives in `ShapeMasking`, shared with camera-only export.
    private func shapeMask(size: CGSize, shape: BubbleShape, tilt: CGFloat) -> CIImage {
        let key = "shape\(shape.rawValue)\(Int(size.width))x\(Int(size.height))t\(Int(tilt))"
        if let cached = maskCache[key] { return cached }
        let image = ShapeMasking.shapeMask(size: size, shape: shape, tilt: tilt)
        maskCache[key] = image
        return image
    }

    // MARK: - Phone mockup

    /// Proportions of the phone body, as fractions of its width.
    /// Tuned to read as a modern iPhone at a glance without pretending to be
    /// a photographic render.
    private enum PhoneMetrics {
        static let bodyCornerRatio: CGFloat = 0.155
        static let bezelRatio: CGFloat = 0.030
        static let islandWidthRatio: CGFloat = 0.30
        static let islandHeightRatio: CGFloat = 0.085
        static let islandTopGapRatio: CGFloat = 0.028
    }

    /// Draws the phone screen inside a phone-shaped body: dark chassis, the
    /// live screen inset within it, and a Dynamic Island pill on top.
    private func drawPhone(
        _ screen: CIImage,
        over background: CIImage,
        settings: CompositorSettings
    ) -> CIImage {
        let rect = settings.phoneRect

        guard settings.phoneShowsFrame else {
            let bare = fit(
                screen, into: rect, mode: .fit, cornerRadius: settings.phoneCornerRadius
            )
            return bare.composited(over: background)
        }

        let bodyCorner = rect.width * PhoneMetrics.bodyCornerRatio
        let bezel = rect.width * PhoneMetrics.bezelRatio
        let screenCorner = max(bodyCorner - bezel, 2)

        var result = background

        // Chassis
        let body = solidRounded(
            size: rect.size,
            cornerRadius: bodyCorner,
            gray: 0.055
        ).transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
        result = body.composited(over: result)

        // Screen
        let screenRect = rect.insetBy(dx: bezel, dy: bezel)
        let inner = fit(screen, into: screenRect, mode: .fit, cornerRadius: screenCorner)
        result = inner.composited(over: result)

        // Dynamic Island
        let islandWidth = rect.width * PhoneMetrics.islandWidthRatio
        let islandHeight = rect.width * PhoneMetrics.islandHeightRatio
        let islandRect = CGRect(
            x: rect.midX - islandWidth / 2,
            y: rect.maxY - bezel - rect.width * PhoneMetrics.islandTopGapRatio - islandHeight,
            width: islandWidth,
            height: islandHeight
        )
        let island = solidRounded(
            size: islandRect.size,
            cornerRadius: islandHeight / 2,
            gray: 0.02
        ).transformed(by: CGAffineTransform(translationX: islandRect.minX, y: islandRect.minY))
        result = island.composited(over: result)

        return result
    }

    /// An opaque rounded rectangle of a flat grey, cached by shape.
    private func solidRounded(size: CGSize, cornerRadius: CGFloat, gray: CGFloat) -> CIImage {
        let key = "solid\(Int(size.width))x\(Int(size.height))r\(Int(cornerRadius))g\(Int(gray * 1000))"
        if let cached = maskCache[key] { return cached }

        let width = max(Int(size.width.rounded()), 1)
        let height = max(Int(size.height.rounded()), 1)

        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .empty() }

        context.setFillColor(red: gray, green: gray, blue: gray + 0.008, alpha: 1)
        context.addPath(
            CGPath(
                roundedRect: CGRect(x: 0, y: 0, width: width, height: height),
                cornerWidth: min(cornerRadius, CGFloat(width) / 2),
                cornerHeight: min(cornerRadius, CGFloat(height) / 2),
                transform: nil
            )
        )
        context.fillPath()

        guard let cgImage = context.makeImage() else { return .empty() }
        let image = CIImage(cgImage: cgImage)
        maskCache[key] = image
        return image
    }

    /// Rounded-rect mask, used by the phone panel. Same alpha requirement as
    /// `shapeMask` above.
    private func roundedMask(size: CGSize, cornerRadius: CGFloat) -> CIImage {
        let key = "rounded\(Int(size.width))x\(Int(size.height))r\(Int(cornerRadius))"
        if let cached = maskCache[key] { return cached }

        let width = max(size.width.rounded(), 1)
        let height = max(size.height.rounded(), 1)
        let path = CGPath(
            roundedRect: CGRect(x: 0, y: 0, width: width, height: height),
            cornerWidth: min(cornerRadius, width / 2),
            cornerHeight: min(cornerRadius, height / 2),
            transform: nil
        )
        let image = ShapeMasking.alphaMask(size: size, path: path)
        maskCache[key] = image
        return image
    }

    private func applyClickRings(
        to frame: CIImage,
        settings: CompositorSettings,
        time: Double,
        size: CGSize
    ) -> CIImage {
        var result = frame
        for click in settings.clicks {
            let age = time - click.time
            guard age >= 0, age <= Self.ringDuration else { continue }

            let progress = age / Self.ringDuration
            let radius = Self.ringMaxRadius * CGFloat(0.35 + 0.65 * progress)
            let alpha = CGFloat(1 - progress) * 0.55

            let center = CGPoint(x: click.x * size.width, y: click.y * size.height)
            let ring = ringSprite()
                .transformed(by: CGAffineTransform(
                    scaleX: radius * 2 / 512, y: radius * 2 / 512
                ))

            let positioned = ring.transformed(by: CGAffineTransform(
                translationX: center.x - radius,
                y: center.y - radius
            ))

            let faded = positioned.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)
            ])
            result = faded.composited(over: result)
        }
        return result
    }

    /// A 512px ring, drawn once and reused.
    private func ringSprite() -> CIImage {
        if let ringImage { return ringImage }

        let side = 512
        guard let context = CGContext(
            data: nil, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .empty() }

        context.setStrokeColor(
            red: Self.ringColor.red,
            green: Self.ringColor.green,
            blue: Self.ringColor.blue,
            alpha: 1
        )
        context.setLineWidth(CGFloat(side) * 0.09)
        let inset = CGFloat(side) * 0.09
        context.strokeEllipse(
            in: CGRect(x: inset, y: inset,
                       width: CGFloat(side) - inset * 2,
                       height: CGFloat(side) - inset * 2)
        )

        guard let cgImage = context.makeImage() else { return .empty() }
        let image = CIImage(cgImage: cgImage)
        ringImage = image
        return image
    }

    enum CompositorError: LocalizedError {
        case noRenderBuffer
        case missingScreenFrame

        var errorDescription: String? {
            switch self {
            case .noRenderBuffer:     return "Could not allocate a frame to render into."
            case .missingScreenFrame: return "A screen frame was missing during export."
            }
        }
    }
}
