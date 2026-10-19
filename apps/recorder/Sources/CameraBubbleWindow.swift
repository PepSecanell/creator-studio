import AppKit
import AVFoundation

/// A floating live preview, the camera bubble, or the iPhone panel.
///
/// A non-activating NSPanel, not a normal window: a regular window would
/// steal focus on every drag, and, window level
/// flags alone are never enough to float over another app's full-screen
/// Space. The panel must be non-activating and joined to all Spaces.
///
/// It never appears in the recording: the capture filter excludes this whole
/// application, so the raw screen file stays clean and the overlay is
/// composited in at export instead. That is what keeps it movable and
/// removable after the fact.
final class CameraBubbleWindow: NSPanel {

    private let hostView: OverlayHostView

    init(previewLayer: AVCaptureVideoPreviewLayer, size: NSSize, cornerRadius: CGFloat) {
        self.hostView = OverlayHostView(previewLayer: previewLayer)

        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        contentView = hostView
        apply(size: size, cornerRadius: cornerRadius)
    }

    /// Panels refuse key status by default, which would break dragging.
    override var canBecomeKey: Bool { true }

    func apply(size: NSSize, cornerRadius: CGFloat) {
        var frame = self.frame
        // Grow from the centre so resizing does not walk the window away.
        frame.origin.x += (frame.width - size.width) / 2
        frame.origin.y += (frame.height - size.height) / 2
        frame.size = size
        setFrame(frame, display: true)
        hostView.cornerRadius = cornerRadius
        hostView.layoutPreview()
        invalidateShadow()
    }

    /// Shows the live screen inside a phone-shaped body, matching what the
    /// compositor will draw, so the preview is what you get.
    func setPhoneFrame(_ enabled: Bool) {
        hostView.showsPhoneFrame = enabled
        hostView.layoutPreview()
    }

    /// Cuts the preview to the same path the compositor will use.
    func setBubbleShape(_ shape: BubbleShape, tiltDegrees: CGFloat) {
        hostView.bubbleShape = shape
        hostView.bubbleTilt = tiltDegrees
        hostView.layoutPreview()
    }

    func setVideoGravity(_ gravity: AVLayerVideoGravity) {
        hostView.setVideoGravity(gravity)
    }

    /// Studio look: the bubble becomes a live copy of the export's face card. /// the card's shape and radius, and exactly `drawCard`'s crop of the
    /// camera (shared `FaceCardFraming`). nil = back to the Classic shape.
    /// The window must already have the framing's aspect (`visibleAspect`).
    func setStudioFraming(_ framing: FaceCardFraming?) {
        guard hostView.studioFraming != framing else { return }
        hostView.studioFraming = framing
        hostView.layoutPreview()
        invalidateShadow()
    }

    /// A faint eye-line and headroom guide for the first few seconds, so
    /// you can line yourself up in the card. Lives only in this panel: the
    /// capture filter excludes the whole app, and the camera file comes
    /// straight from the device, so it can never reach a recording.
    func flashFramingGuide(seconds: TimeInterval = 5) {
        hostView.flashGuide(seconds: seconds)
    }

    /// The framing assistant's compact status: a traffic light and one short
    /// hint in a pill at the bottom of the bubble. Like the guide, it lives
    /// only in this panel (the capture excludes the whole app; camera.mov is
    /// written from the device's own buffers). nil hides it.
    func setFramingStatus(_ status: FramingStatus?, hint: String) {
        hostView.setPill(status: status, text: hint, scale: backingScaleFactor)
    }

    /// Studio's default spot: the same side of the screen as the card in the
    /// export. Only a starting point, in Studio the card is placed by the
    /// export, so where the bubble is dragged changes nothing in the file.
    func moveToStudioSlot(on screen: NSScreen, face: FaceLayout) {
        let area = screen.visibleFrame
        let margin: CGFloat = 40
        switch face {
        case .tallLeft:
            setFrameOrigin(NSPoint(x: area.minX + margin, y: area.midY - frame.height / 2))
        case .bottomRight:
            setFrameOrigin(NSPoint(x: area.maxX - frame.width - margin, y: area.minY + margin))
        }
    }

    func moveToCorner(on screen: NSScreen, leading: Bool) {
        let margin: CGFloat = 40
        let origin = NSPoint(
            x: leading
                ? screen.frame.minX + margin
                : screen.frame.maxX - frame.width - margin,
            y: screen.frame.minY + margin
        )
        setFrameOrigin(origin)
    }

    /// Where this panel sits inside the recorded frame, in output pixels,
    /// origin bottom-left to match Core Image.
    func rectInRenderSpace(screen: NSScreen, renderSize: CGSize) -> CGRect {
        let panel = frame
        let bounds = screen.frame
        guard bounds.width > 0, bounds.height > 0 else { return .zero }

        return CGRect(
            x: (panel.minX - bounds.minX) / bounds.width * renderSize.width,
            y: (panel.minY - bounds.minY) / bounds.height * renderSize.height,
            width: panel.width / bounds.width * renderSize.width,
            height: panel.height / bounds.height * renderSize.height
        )
    }
}

private final class OverlayHostView: NSView {

    /// Must stay in step with PhoneMetrics in StudioCompositor, or the
    /// preview and the finished video would disagree.
    private enum PhoneMetrics {
        static let bodyCornerRatio: CGFloat = 0.155
        static let bezelRatio: CGFloat = 0.030
        static let islandWidthRatio: CGFloat = 0.30
        static let islandHeightRatio: CGFloat = 0.085
        static let islandTopGapRatio: CGFloat = 0.028
    }

    private let previewLayer: AVCaptureVideoPreviewLayer
    private let islandLayer = CALayer()
    private let shapeMask = CAShapeLayer()
    private let guideLayer = CAShapeLayer()
    private var guideHide: DispatchWorkItem?
    private let pillLayer = CALayer()
    private let pillDot = CALayer()
    private let pillText = CATextLayer()
    private var pillString = ""
    var cornerRadius: CGFloat = 0
    /// Studio: mirror the export's face card instead of `bubbleShape`.
    var studioFraming: FaceCardFraming?
    var showsPhoneFrame = false
    /// nil = plain rounded corners (used by the phone panel).
    var bubbleShape: BubbleShape?
    var bubbleTilt: CGFloat = 0

    init(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)

        islandLayer.backgroundColor = NSColor(white: 0.02, alpha: 1).cgColor
        islandLayer.isHidden = true
        layer?.addSublayer(islandLayer)

        guideLayer.fillColor = nil
        guideLayer.strokeColor = NSColor(srgbRed: 0.961, green: 0.929, blue: 0.847, alpha: 0.75).cgColor
        guideLayer.lineWidth = 1
        guideLayer.lineDashPattern = [5, 4]
        guideLayer.opacity = 0
        layer?.addSublayer(guideLayer)

        pillLayer.backgroundColor = NSColor(white: 0, alpha: 0.62).cgColor
        pillLayer.isHidden = true
        pillText.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        pillText.fontSize = 11
        pillText.foregroundColor = NSColor.white.cgColor
        pillText.alignmentMode = .left
        pillText.truncationMode = .end
        pillLayer.addSublayer(pillDot)
        pillLayer.addSublayer(pillText)
        layer?.addSublayer(pillLayer)
    }

    func setPill(status: FramingStatus?, text: String, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let status, !showsPhoneFrame else {
            pillLayer.isHidden = true
            return
        }
        pillLayer.isHidden = false
        pillDot.backgroundColor = status.nsColor.cgColor
        pillText.contentsScale = scale
        pillLayer.contentsScale = scale
        if pillString != text {
            pillString = text
            pillText.string = text
        }
        layoutPill()
    }

    /// Bottom centre, inside a circle's chord at that height, so it reads
    /// on every bubble shape.
    private func layoutPill() {
        guard !pillLayer.isHidden else { return }
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let textWidth = ceil((pillString as NSString).size(withAttributes: [.font: font]).width)
        let height: CGFloat = 20
        // A circle's chord at that height is ~72% of the width; a Studio card
        // is a rectangle, so it can use nearly all of it.
        let maxWidth = studioFraming != nil ? bounds.width - 14 : bounds.width * 0.72
        let width = min(maxWidth, textWidth + 30)
        pillLayer.frame = CGRect(x: bounds.midX - width / 2, y: bounds.height * 0.09, width: width, height: height)
        pillLayer.cornerRadius = height / 2
        pillDot.frame = CGRect(x: 9, y: (height - 8) / 2, width: 8, height: 8)
        pillDot.cornerRadius = 4
        pillText.frame = CGRect(x: 22, y: (height - 14) / 2, width: width - 29, height: 15)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        layoutPreview()
    }

    func setVideoGravity(_ gravity: AVLayerVideoGravity) {
        previewLayer.videoGravity = gravity
    }

    /// Eye line a third of the way down the card, and a headroom line above
    /// it: where the eyes and the top of the head should sit.
    private func layoutGuide() {
        guideLayer.frame = bounds
        let path = CGMutablePath()
        let inset = bounds.width * 0.12
        for share in [0.36, 0.10] as [CGFloat] {
            let y = bounds.maxY - bounds.height * share
            path.move(to: CGPoint(x: bounds.minX + inset, y: y))
            path.addLine(to: CGPoint(x: bounds.maxX - inset, y: y))
        }
        guideLayer.path = path
    }

    func flashGuide(seconds: TimeInterval) {
        guideHide?.cancel()
        guard studioFraming != nil else {
            guideLayer.opacity = 0
            return
        }
        layoutGuide()
        guideLayer.opacity = 1
        let hide = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = 0.8
            self.guideLayer.add(fade, forKey: "fade")
            self.guideLayer.opacity = 0
        }
        guideHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: hide)
    }

    func layoutPreview() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        layoutPill()

        if studioFraming == nil || showsPhoneFrame { guideLayer.opacity = 0 }

        guard showsPhoneFrame else {
            layer?.backgroundColor = NSColor.clear.cgColor
            previewLayer.frame = bounds
            previewLayer.masksToBounds = true
            islandLayer.isHidden = true

            if let framing = studioFraming {
                // The export's card, not a circle: same crop, same corners.
                layer?.cornerRadius = 0
                previewLayer.cornerRadius = 0
                let mapped = framing.mapped(into: bounds)
                previewLayer.frame = mapped.camera
                // The mask lives in the preview layer's own coordinates.
                var toLayer = CGAffineTransform(translationX: -mapped.camera.minX, y: -mapped.camera.minY)
                shapeMask.frame = previewLayer.bounds
                shapeMask.path = mapped.card.copy(using: &toLayer)
                previewLayer.mask = shapeMask
                layoutGuide()
            } else if let bubbleShape {
                // Same path generator the compositor uses, so what is on
                // screen is what lands in the file.
                layer?.cornerRadius = 0
                previewLayer.cornerRadius = 0
                shapeMask.frame = bounds
                shapeMask.path = BubbleShapePath.path(
                    for: bubbleShape, in: bounds, tiltDegrees: bubbleTilt
                )
                previewLayer.mask = shapeMask
            } else {
                previewLayer.mask = nil
                layer?.cornerRadius = cornerRadius
                previewLayer.cornerRadius = cornerRadius
            }
            return
        }

        previewLayer.mask = nil

        let width = bounds.width
        let bodyCorner = width * PhoneMetrics.bodyCornerRatio
        let bezel = width * PhoneMetrics.bezelRatio

        layer?.backgroundColor = NSColor(white: 0.055, alpha: 1).cgColor
        layer?.cornerRadius = bodyCorner

        previewLayer.frame = bounds.insetBy(dx: bezel, dy: bezel)
        previewLayer.cornerRadius = max(bodyCorner - bezel, 2)
        previewLayer.masksToBounds = true

        let islandWidth = width * PhoneMetrics.islandWidthRatio
        let islandHeight = width * PhoneMetrics.islandHeightRatio
        islandLayer.isHidden = false
        islandLayer.cornerRadius = islandHeight / 2
        islandLayer.frame = CGRect(
            x: bounds.midX - islandWidth / 2,
            y: bounds.maxY - bezel - width * PhoneMetrics.islandTopGapRatio - islandHeight,
            width: islandWidth,
            height: islandHeight
        )
    }
}
