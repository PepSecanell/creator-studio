import AppKit
import AVFoundation
import AVKit
import SwiftUI

// Short mode's live preview. The whole camera image with the
// fixed 9:16 window drawn on it, everything outside dimmed, plus faint
// short-form safe zones inside it, so you see exactly what viewers will
// see while you record. The window is dragged left/right (and up/down when
// the feed has room) before Record; during a take it is locked.
//
// Nothing here can reach a take: Short mode never runs ScreenCaptureKit, and
// take.mov is written from the camera's own sample buffers.

// MARK: - Geometry

/// Where things go in the view (top-left points).
struct ShortStageLayout {
    /// The whole camera frame on screen.
    let camera: CGRect
    /// The 9:16 crop on screen.
    let crop: CGRect
    /// The visible picture (camera in "Whole camera", crop in "Viewer view").
    let visible: CGRect
    /// Screen points per camera pixel.
    let scale: CGFloat

    init(size: CGSize, frame: CGSize, cropPixels: CGRect, viewerView: Bool, inset: CGFloat = 10) {
        let frame = frame.width >= 2 && frame.height >= 2 ? frame : CGSize(width: 1920, height: 1440)
        let area = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        let target = viewerView ? cropPixels.size : frame
        let fit = min(area.width / max(target.width, 1), area.height / max(target.height, 1))
        let shown = CGSize(width: target.width * fit, height: target.height * fit)
        let origin = CGPoint(x: area.midX - shown.width / 2, y: area.midY - shown.height / 2)
        scale = fit
        if viewerView {
            crop = CGRect(origin: origin, size: shown)
            camera = CGRect(x: origin.x - cropPixels.minX * fit, y: origin.y - cropPixels.minY * fit,
                            width: frame.width * fit, height: frame.height * fit)
            visible = crop
        } else {
            camera = CGRect(origin: origin, size: shown)
            crop = CGRect(x: origin.x + cropPixels.minX * fit, y: origin.y + cropPixels.minY * fit,
                          width: cropPixels.width * fit, height: cropPixels.height * fit)
            visible = camera
        }
    }

    /// A rect in finished-frame pixels (1080x1920) → screen.
    func onScreen(_ r: CGRect) -> CGRect {
        let s = crop.width / ShortFraming.outputSize.width
        return CGRect(x: crop.minX + r.minX * s, y: crop.minY + r.minY * s, width: r.width * s, height: r.height * s)
    }

    /// A point in normalised camera space (top-left, 0…1) → screen. Used by
    /// the framing guide, which is drawn in the same space `FramingReport`
    /// measures in (`FramingStageLayout.point` in FramingAssistant.swift is
    /// the sibling for the Just me / Screen window).
    func point(_ p: CGPoint) -> CGPoint {
        CGPoint(x: camera.minX + p.x * camera.width, y: camera.minY + p.y * camera.height)
    }
}

// MARK: - Stage

struct ShortFrameStage: View {
    enum Content {
        case live(AVCaptureVideoPreviewLayer?)
        case still(CGImage?)
    }

    let content: Content
    let frameSize: CGSize
    @Binding var position: ShortFraming.Position
    var locked: Bool
    var safeZones: Bool
    var viewerView: Bool
    /// Eye-line + face-size guide, and the live coaching that
    /// goes with it. `.idle` draws nothing extra.
    var framingGuide = true
    var framing: FramingReport = .idle

    @State private var dragStart: ShortFraming.Position?

    private let cream = Color(red: 0.961, green: 0.929, blue: 0.847)
    private let rose = Color(red: 0.831, green: 0.643, blue: 0.604)

    var body: some View {
        GeometryReader { geo in
            let cropPx = ShortFraming.cropRect(frame: frameSize, position: position)
            let layout = ShortStageLayout(size: geo.size, frame: frameSize, cropPixels: cropPx, viewerView: viewerView)
            ZStack(alignment: .topLeading) {
                Color(white: 0.07)
                picture(layout: layout)
                overlay(layout: layout)
                    .allowsHitTesting(false)
                if !viewerView {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(drag(layout: layout))
                }
            }
        }
    }

    @ViewBuilder
    private func picture(layout: ShortStageLayout) -> some View {
        switch content {
        case .live(let layer):
            LivePreviewView(layer: layer, cameraRect: layout.camera, mask: CGPath(rect: layout.visible, transform: nil))
        case .still(let image):
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: layout.camera.width, height: layout.camera.height)
                    .offset(x: layout.camera.minX, y: layout.camera.minY)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .mask(alignment: .topLeading) { Path(layout.visible) }
            }
        }
    }

    private func overlay(layout: ShortStageLayout) -> some View {
        Canvas { ctx, _ in
            let crop = layout.crop
            if !viewerView {
                // Dim everything the viewer will never see.
                var dim = Path(layout.camera)
                dim.addPath(Path(crop))
                ctx.fill(dim, with: .color(.black.opacity(0.62)), style: FillStyle(eoFill: true))
            }

            if safeZones {
                let labelSize: CGFloat = crop.width > 300 ? 10 : 8
                for zone in ShortFraming.safeZones {
                    let r = layout.onScreen(zone.rect)
                    switch zone.kind {
                    case .keepClear:
                        ctx.fill(Path(r), with: .color(.white.opacity(0.06)))
                        ctx.stroke(Path(r.insetBy(dx: 0.5, dy: 0.5)), with: .color(.white.opacity(0.28)),
                                   style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    case .captions:
                        ctx.fill(Path(r), with: .color(rose.opacity(0.16)))
                        ctx.stroke(Path(r.insetBy(dx: 0.5, dy: 0.5)), with: .color(rose.opacity(0.75)),
                                   style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                    }
                    if crop.width > 150 {
                        let label = Text(zone.name).font(.system(size: labelSize, weight: .medium))
                            .foregroundColor(cream.opacity(zone.kind == .captions ? 0.9 : 0.55))
                        if zone.name == "buttons" {
                            ctx.draw(label, at: CGPoint(x: r.midX, y: r.minY + 6), anchor: .top)
                        } else {
                            ctx.draw(label, at: CGPoint(x: r.minX + 6, y: r.minY + 4), anchor: .topLeading)
                        }
                    }
                }
            }

            // Eye-line band, a face-size oval, and (when a face is found) the
            // live eye markers, approximating the editor's
            // own targets (eyes at 0.40, face ≈580 of 1920 tall ≈ 0.302 of
            // the crop's height) inside whichever frame is on screen right
            // now. The live markers use `layout.point`, in camera space, so
            // they read correctly regardless of where the frame is dragged;
            // the target bands are drawn relative to `crop` so they always
            // sit on the frame itself. Inlined in this closure (not a
            // separate function) because Canvas's `ctx` here can't be
            // forwarded as `inout` to another function.
            if framingGuide, crop.width > 40, crop.height > 40 {
                let target = FramingTarget.short
                let status = framing.perCrop.first?.status ?? .unknown
                let color = status.shortColor

                let band = CGRect(
                    x: crop.minX, y: crop.minY + target.eyeBand.lowerBound * crop.height,
                    width: crop.width, height: (target.eyeBand.upperBound - target.eyeBand.lowerBound) * crop.height
                )
                ctx.fill(Path(band), with: .color(rose.opacity(0.14)))
                var bandEdges = Path()
                for y in [band.minY, band.maxY] {
                    bandEdges.move(to: CGPoint(x: band.minX, y: y)); bandEdges.addLine(to: CGPoint(x: band.maxX, y: y))
                }
                ctx.stroke(bandEdges, with: .color(rose.opacity(0.65)), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))

                // A face-size oval: height = the faceHeight target's midpoint
                // of the crop, centred where the eye line (33% down the
                // oval, matching FaceMeasurement's own fallback) lands on
                // the eye-line band's midpoint.
                let faceMid = (target.faceHeight.lowerBound + target.faceHeight.upperBound) / 2
                let eyeMid = (target.eyeBand.lowerBound + target.eyeBand.upperBound) / 2
                let ovalHeight = faceMid * crop.height
                let ovalWidth = ovalHeight * 0.76
                let ovalTop = crop.minY + (eyeMid - 0.33 * faceMid) * crop.height
                let ovalRect = CGRect(x: crop.midX - ovalWidth / 2, y: ovalTop, width: ovalWidth, height: ovalHeight)
                ctx.stroke(Path(ellipseIn: ovalRect), with: .color(cream.opacity(0.55)), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))

                if crop.width > 140 {
                    ctx.draw(Text("eyes here").font(.system(size: crop.width > 340 ? 11 : 9, weight: .semibold)).foregroundColor(cream.opacity(0.85)),
                             at: CGPoint(x: band.maxX - 8, y: band.midY), anchor: .trailing)
                }

                // A scoped layer, not `ctx.clip(...)` directly: the frame
                // border still has to draw its full 1px ring outside `crop`
                // right after this, unclipped.
                if let face = framing.face {
                    ctx.drawLayer { layer in
                        layer.clip(to: Path(layout.visible))
                        let a: CGPoint, b: CGPoint
                        if let eyes = face.eyes {
                            a = layout.point(eyes.0); b = layout.point(eyes.1)
                        } else {
                            a = layout.point(CGPoint(x: face.face.minX + 0.25 * face.face.width, y: face.eyeY))
                            b = layout.point(CGPoint(x: face.face.maxX - 0.25 * face.face.width, y: face.eyeY))
                        }
                        let dx = b.x - a.x, dy = b.y - a.y
                        var line = Path()
                        line.move(to: CGPoint(x: a.x - dx * 0.6, y: a.y - dy * 0.6))
                        line.addLine(to: CGPoint(x: b.x + dx * 0.6, y: b.y + dy * 0.6))
                        layer.stroke(line, with: .color(color.opacity(0.9)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        for p in [a, b] {
                            layer.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(color))
                        }
                    }
                }
            }

            // The frame itself.
            ctx.stroke(Path(crop.insetBy(dx: -1, dy: -1)), with: .color(cream.opacity(0.95)), lineWidth: 2)
        }
    }

    private func drag(layout: ShortStageLayout) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard !locked else { return }
                let start = dragStart ?? position
                if dragStart == nil { dragStart = position }
                let travel = ShortFraming.travel(frame: frameSize)
                var next = start
                if travel.width >= 2, layout.scale > 0 {
                    next.x = start.x + Double(value.translation.width / layout.scale / travel.width)
                }
                if travel.height >= 2, layout.scale > 0 {
                    next.y = start.y + Double(value.translation.height / layout.scale / travel.height)
                }
                next = next.clamped
                if next != position { position = next }
            }
            .onEnded { _ in dragStart = nil }
    }
}

// MARK: - Framing badge

/// The guide's status + hint, drawn over the stage. Brand
/// colours only, cream / dusty rose / chocolate, never the Just me / Screen
/// "Check framing" window's red-orange-green traffic light (`FramingStatus
/// .shortColor` in ShortFramingHints.swift).
struct ShortFramingBadge: View {
    let advice: FramingAdvice
    private let cream = Color(red: 0.961, green: 0.929, blue: 0.847)

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(advice.status.shortColor)
                .frame(width: 9, height: 9)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(advice.hints.prefix(2).enumerated()), id: \.offset) { index, hint in
                    Text(hint)
                        .font(.system(size: index == 0 ? 12 : 10, weight: index == 0 ? .semibold : .regular))
                        .foregroundStyle(cream.opacity(index == 0 ? 0.95 : 0.7))
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Timer colour

extension ShortFraming.LengthBand {
    var color: Color {
        switch self {
        case .normal: return .white
        case .amber: return Color(nsColor: .systemOrange)
        case .red: return Color(nsColor: .systemRed)
        }
    }
}

// MARK: - Window content

/// Pure view (it can be snapshotted with a still frame).
struct ShortPreviewView: View {
    let content: ShortFrameStage.Content
    let frameSize: CGSize
    @Binding var position: ShortFraming.Position
    @Binding var safeZones: Bool
    @Binding var framingGuide: Bool
    /// The live guide's read of the current frame: eye-line +
    /// face-size targets, drawn by `ShortFrameStage`, plus the coaching text
    /// shown below it. `.idle` while the analyser hasn't produced one yet.
    var framing: FramingReport = .idle
    var locked: Bool
    var recording: Bool
    var elapsed: TimeInterval
    var canReplay: Bool
    /// The title of the Studio app's request, if any ("Recording: <title>").
    var scriptTitle: String? = nil
    /// True when the preview is a mirror but the recorded file is not. In
    /// Viewer view the picture then shows the FILE's orientation (the live
    /// layer's mirroring is switched by the controller; a still is passed in
    /// already flipped), so the frame sits at the file's position, 1 - x.
    var flipViewer: Bool = false
    var onCentre: () -> Void = {}
    var onReplay: () -> Void = {}
    var onClearScript: () -> Void = {}
    var onViewerViewChange: (Bool) -> Void = { _ in }

    @State var viewerView = false
    private let cream = Color(red: 0.961, green: 0.929, blue: 0.847)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(String(format: "%02d:%02d", Int(elapsed) / 60, Int(elapsed) % 60))
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .foregroundStyle(recording ? ShortFraming.lengthBand(elapsed).color : cream.opacity(0.45))
                    .help("Amber from 40 s, red from 60 s.")
                Label(locked ? "Locked for this take" : "Drag the frame to place it",
                      systemImage: locked ? "lock.fill" : "arrow.left.and.right")
                    .font(.system(size: 11))
                    .foregroundStyle(cream.opacity(0.6))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Picker("", selection: $viewerView) {
                    Text("Whole camera").tag(false)
                    Text("Viewer view").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 190)
                Toggle("Safe zones", isOn: $safeZones)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                Toggle("Framing guide", isOn: $framingGuide)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .help("Eye line + face size, approximating the editor's own crop. Never recorded, and never required, it only coaches.")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if let scriptTitle {
                HStack(spacing: 8) {
                    Text("Recording: \(scriptTitle)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(cream.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    Button("Not this one", action: onClearScript)
                        .controlSize(.mini)
                        .disabled(locked)
                        .help("Ignore this request for the next takes. They go to a plain free-take folder. A new press in the Studio app brings a request back.")
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }

            ZStack(alignment: .bottomLeading) {
                ShortFrameStage(
                    content: content, frameSize: frameSize,
                    position: viewerView && flipViewer
                        ? .constant(ShortFraming.Position(x: 1 - position.x, y: position.y))
                        : $position,
                    locked: locked, safeZones: safeZones, viewerView: viewerView,
                    framingGuide: framingGuide, framing: framing
                )
                if framingGuide {
                    ShortFramingBadge(advice: framing.overall)
                        .padding(10)
                }
            }
            .frame(minHeight: 280)

            HStack(spacing: 8) {
                Text(ShortFraming.describe(frame: frameSize))
                    .font(.system(size: 11))
                    .foregroundStyle(cream.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Button("Centre", action: onCentre)
                    .controlSize(.small)
                    .disabled(locked || ShortFraming.isWholeFrame(frameSize))
                Button {
                    onReplay()
                } label: {
                    Label("Last take", systemImage: "play.fill")
                }
                .controlSize(.small)
                .disabled(!canReplay || recording)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(white: 0.10))
        .environment(\.colorScheme, .dark)
        .onChange(of: viewerView) { _, on in onViewerViewChange(on) }
        .onAppear { onViewerViewChange(viewerView) }
    }
}

/// Binds the pure view to the controller. A second `@ObservedObject` on
/// `shortFraming` (not just `controller`) is what makes the guide + badge
/// redraw as new reports arrive, they live on the monitor's own
/// `@Published`, a different object from the controller.
struct ShortPreviewContainer: View {
    @ObservedObject var controller: RecordingController
    @ObservedObject var framingMonitor: FramingMonitor

    init(controller: RecordingController) {
        self.controller = controller
        self.framingMonitor = controller.shortFraming
    }

    var body: some View {
        ShortPreviewView(
            content: .live(controller.shortPreviewLayer),
            frameSize: controller.shortFrameSize,
            position: $controller.shortPosition,
            safeZones: $controller.shortSafeZones,
            framingGuide: $controller.shortFramingGuide,
            framing: framingMonitor.report,
            locked: controller.shortCropLocked,
            recording: controller.phase.isActive,
            elapsed: controller.phase.isActive ? controller.elapsed : 0,
            canReplay: controller.lastShortURL != nil,
            scriptTitle: controller.shortHeaderHandoff.map { $0.title.isEmpty ? $0.id : "\($0.id) · \($0.title)" },
            flipViewer: controller.mirrorCamera != controller.shortMirrorFile,
            onCentre: { controller.centreShortCrop() },
            onReplay: { controller.replayLastShort() },
            onClearScript: { controller.ignoreHandoff() },
            onViewerViewChange: { controller.setShortViewerView($0) }
        )
    }
}

// MARK: - Windows

/// Floating so it stays above other windows while you line up the shot.
final class ShortPreviewWindow: NSWindow, NSWindowDelegate {
    var onClose: (() -> Void)?

    init(controller: RecordingController) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        title = "Short frame"
        isReleasedWhenClosed = false
        level = .floating
        collectionBehavior = [.fullScreenAuxiliary]
        minSize = NSSize(width: 420, height: 380)
        contentView = NSHostingView(rootView: ShortPreviewContainer(controller: controller))
        delegate = self
        center()
        setFrameAutosaveName("ShortFrameWindow")
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

/// "Last take": plays short.mov right away, sized to the vertical frame.
final class ShortReplayWindow: NSWindow {
    private let playerView = AVPlayerView()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        level = .floating
        contentAspectRatio = NSSize(width: 9, height: 16)
        playerView.controlsStyle = .floating
        contentView = playerView
        center()
        setFrameAutosaveName("ShortReplayWindow")
    }

    func play(_ url: URL) {
        title = "Last take, \(url.deletingLastPathComponent().lastPathComponent)"
        playerView.player?.pause()
        playerView.player = AVPlayer(url: url)
        makeKeyAndOrderFront(nil)
        playerView.player?.play()
    }

    override func close() {
        playerView.player?.pause()
        super.close()
    }
}
