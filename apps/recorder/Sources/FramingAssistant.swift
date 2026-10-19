import AppKit
import AVFoundation
import CoreImage
import SwiftUI

// The framing assistant's face: a big live preview of
// exactly what will be recorded, every crop you can appear in for the current
// settings, with guides and calm, plain-English hints. The analysis and the
// hint rules live in FramingAnalysis.swift.
//
// Nothing here can reach a take: this is an app window (ScreenRecorder's
// filter excludes the whole app), the guides are SwiftUI drawing on top of a
// preview layer, and take.mov is written from the device's own
// sample buffers, the monitor only ever reads a copy (`CameraFrameTap`).

// MARK: - Monitor: runs the analysis loop off the capture queue

@MainActor
final class FramingMonitor: ObservableObject {
    @Published private(set) var report: FramingReport = .idle
    @Published private(set) var specs: [FramingCropSpec] = []
    @Published private(set) var mirrored = true
    /// The newest analysed frame (640 px wide), for the crop thumbnails.
    @Published private(set) var thumbnail: CGImage?
    /// The live preview for the big stage (a second preview layer on the
    /// recorder's own session, so it is the same camera, format and mirror).
    @Published var livePreview: AVCaptureVideoPreviewLayer?

    private var source: CameraFrameTap?
    private var interval: Duration = .milliseconds(170)
    private var loop: Task<Void, Never>?
    private let analyzer = FramingAnalyzer()
    private let coach = FramingCoach()

    /// How one issue becomes a line, and what the good state says. Default =
    /// the shared Just me / Screen wording; Short mode's own monitor sets
    /// this once to `ShortFramingHints` so its coaching reads in its own
    /// voice (see `FramingCoach.step(message:good:)`). nil = the coach's own
    /// default, which words Just me → Full's "too close" around showing your hands.
    var messageProvider: ((FramingIssueKind, Bool, Bool, String?) -> String)? = nil
    var goodAdvice: FramingAdvice = .good

    var isRunning: Bool { loop != nil }

    /// ~6 analyses a second normally; 2 a second while a take is recording,
    /// so it never competes with the capture.
    func update(specs: [FramingCropSpec], mirrored: Bool, source: CameraFrameTap?, slow: Bool) {
        if self.specs != specs { self.specs = specs; coach.reset() }
        if self.mirrored != mirrored { self.mirrored = mirrored }
        interval = slow ? .milliseconds(500) : .milliseconds(170)
        let changed = source !== self.source
        self.source = source
        if source == nil {
            loop?.cancel()
            loop = nil
            if report != .idle { report = .idle }
            thumbnail = nil
            coach.reset()
        } else if changed || loop == nil {
            coach.reset()
            start()
        }
    }

    private func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let buffer = self.source?.latest()
                let analyzer = self.analyzer
                let result = await Task.detached(priority: .utility) { () -> (FrameReading, CGImage)? in
                    guard let buffer else { return nil }
                    return analyzer.analyze(CIImage(cvPixelBuffer: buffer))
                }.value
                if Task.isCancelled { return }
                let next = self.coach.step(
                    result?.0, specs: self.specs, mirrored: self.mirrored,
                    now: ProcessInfo.processInfo.systemUptime,
                    message: self.messageProvider, good: self.goodAdvice
                )
                if next != self.report { self.report = next }
                self.thumbnail = result?.1
                try? await Task.sleep(for: self.interval)
            }
        }
    }
}

// MARK: - Colours

extension FramingStatus {
    var color: Color {
        switch self {
        case .good: return Color(nsColor: .systemGreen)
        case .adjust: return Color(nsColor: .systemOrange)
        case .fix: return Color(nsColor: .systemRed)
        case .unknown: return Color.gray
        }
    }

    var nsColor: NSColor {
        switch self {
        case .good: return .systemGreen
        case .adjust: return .systemOrange
        case .fix: return .systemRed
        case .unknown: return .systemGray
        }
    }
}

// MARK: - Stage: one crop (or the whole sensor) + guides

/// What fills the stage: the live preview layer, or a still (for
/// thumbnails).
enum FramingStageContent {
    case live(AVCaptureVideoPreviewLayer?)
    case still(CGImage?)
}

/// Where things go on the stage, all in the view's own top-left coordinates.
struct FramingStageLayout {
    /// The displayed area (a crop, or the whole camera frame).
    let stage: CGRect
    /// Where the whole camera frame lands.
    let camera: CGRect
    /// Selected crop's rect on the stage (== stage unless showing the sensor).
    let cropRect: CGRect?

    init(size: CGSize, cameraSize: CGSize, crop: ResolvedFramingCrop?, sensor: Bool) {
        let camAspect = cameraSize.width > 0 && cameraSize.height > 0 ? cameraSize.width / cameraSize.height : 16.0 / 9.0
        let showCrop = (crop != nil && !sensor)
        let region = showCrop ? crop!.region : CGRect(x: 0, y: 0, width: 1, height: 1)
        let aspect = showCrop ? crop!.aspect : camAspect
        var w = size.width, h = w / aspect
        if h > size.height { h = size.height; w = h * aspect }
        let stage = CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
        let camW = w / region.width, camH = h / region.height
        let camera = CGRect(x: stage.minX - region.minX * camW, y: stage.minY - region.minY * camH, width: camW, height: camH)
        self.stage = stage
        self.camera = camera
        if let crop {
            let r = crop.region
            cropRect = CGRect(x: camera.minX + r.minX * camW, y: camera.minY + r.minY * camH,
                              width: r.width * camW, height: r.height * camH)
        } else {
            cropRect = nil
        }
    }

    func point(_ p: CGPoint) -> CGPoint {
        CGPoint(x: camera.minX + p.x * camera.width, y: camera.minY + p.y * camera.height)
    }
}

struct FramingStage: View {
    let content: FramingStageContent
    let cameraSize: CGSize
    let crop: ResolvedFramingCrop?
    /// Every crop for these settings (outlined when showing the sensor).
    var allCrops: [ResolvedFramingCrop] = []
    var sensor = false
    var guides = true
    var face: FaceMeasurement?
    var status: FramingStatus = .unknown

    var body: some View {
        GeometryReader { geo in
            let layout = FramingStageLayout(size: geo.size, cameraSize: cameraSize, crop: crop, sensor: sensor)
            let mask: CGPath? = (sensor ? nil : crop).map { $0.maskPath(in: layout.stage) }
            ZStack(alignment: .topLeading) {
                Color(white: 0.07)
                camera(layout: layout, mask: mask)
                if guides {
                    guideLayer(layout: layout)
                }
            }
        }
    }

    @ViewBuilder
    private func camera(layout: FramingStageLayout, mask: CGPath?) -> some View {
        switch content {
        case .live(let layer):
            LivePreviewView(layer: layer, cameraRect: layout.camera, mask: mask ?? CGPath(rect: layout.stage, transform: nil))
        case .still(let image):
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: layout.camera.width, height: layout.camera.height)
                    .offset(x: layout.camera.minX, y: layout.camera.minY)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .mask(alignment: .topLeading) {
                        Path(mask ?? CGPath(rect: layout.stage, transform: nil))
                    }
            }
        }
    }

    private func guideLayer(layout: FramingStageLayout) -> some View {
        Canvas { ctx, size in
            let cream = Color(red: 0.961, green: 0.929, blue: 0.847)
            // Showing the whole sensor: dim what is not recorded, outline the
            // selected crop and (faintly) the others.
            if sensor, let crop, let cropRect = layout.cropRect {
                let selected = Path(crop.maskPath(in: cropRect))
                var dim = Path(CGRect(origin: .zero, size: size))
                dim.addPath(selected)
                ctx.fill(dim, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
                for other in allCrops where other != crop {
                    let r = other.region
                    let rect = CGRect(x: layout.camera.minX + r.minX * layout.camera.width,
                                      y: layout.camera.minY + r.minY * layout.camera.height,
                                      width: r.width * layout.camera.width, height: r.height * layout.camera.height)
                    ctx.stroke(Path(other.maskPath(in: rect)), with: .color(cream.opacity(0.35)),
                               style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                    ctx.draw(Text(other.name).font(.system(size: 10, weight: .medium)).foregroundColor(cream.opacity(0.6)),
                             at: CGPoint(x: rect.minX + 8, y: rect.minY + 6), anchor: .topLeading)
                }
                ctx.stroke(selected, with: .color(cream.opacity(0.95)), lineWidth: 2)
            }

            guard let target = crop?.target, let area = (sensor ? layout.cropRect : layout.stage) else { return }
            let thin = StrokeStyle(lineWidth: 1)
            // Rule of thirds.
            var thirds = Path()
            for i in 1...2 {
                let x = area.minX + area.width * CGFloat(i) / 3
                let y = area.minY + area.height * CGFloat(i) / 3
                thirds.move(to: CGPoint(x: x, y: area.minY)); thirds.addLine(to: CGPoint(x: x, y: area.maxY))
                thirds.move(to: CGPoint(x: area.minX, y: y)); thirds.addLine(to: CGPoint(x: area.maxX, y: y))
            }
            ctx.stroke(thirds, with: .color(.white.opacity(0.18)), style: thin)
            // Centre line.
            var centre = Path()
            centre.move(to: CGPoint(x: area.midX, y: area.minY)); centre.addLine(to: CGPoint(x: area.midX, y: area.maxY))
            ctx.stroke(centre, with: .color(.white.opacity(0.30)), style: StrokeStyle(lineWidth: 1, dash: [4, 6]))
            // Headroom zone: where the top of the head should land.
            let head = CGRect(x: area.minX, y: area.minY + target.headTop.lowerBound * area.height,
                              width: area.width, height: (target.headTop.upperBound - target.headTop.lowerBound) * area.height)
            ctx.fill(Path(head), with: .color(cream.opacity(0.08)))
            var headEdge = Path()
            headEdge.move(to: CGPoint(x: head.minX, y: head.minY)); headEdge.addLine(to: CGPoint(x: head.maxX, y: head.minY))
            ctx.stroke(headEdge, with: .color(cream.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
            // Eye-line band.
            let band = CGRect(x: area.minX, y: area.minY + target.eyeBand.lowerBound * area.height,
                              width: area.width, height: (target.eyeBand.upperBound - target.eyeBand.lowerBound) * area.height)
            ctx.fill(Path(band), with: .color(Color(red: 0.831, green: 0.643, blue: 0.604).opacity(0.16)))
            var bandEdges = Path()
            for y in [band.minY, band.maxY] {
                bandEdges.move(to: CGPoint(x: band.minX, y: y)); bandEdges.addLine(to: CGPoint(x: band.maxX, y: y))
            }
            ctx.stroke(bandEdges, with: .color(Color(red: 0.831, green: 0.643, blue: 0.604).opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
            let labelSize: CGFloat = area.width > 360 ? 11 : 9
            if area.width > 160 {
                ctx.draw(Text("eyes here").font(.system(size: labelSize, weight: .semibold)).foregroundColor(cream.opacity(0.85)),
                         at: CGPoint(x: band.maxX - 8, y: band.midY), anchor: .trailing)
                ctx.draw(Text("top of head").font(.system(size: labelSize)).foregroundColor(cream.opacity(0.6)),
                         at: CGPoint(x: head.maxX - 8, y: head.midY), anchor: .trailing)
            }
            // Where your eyes actually are right now (kept inside the picture).
            ctx.clip(to: Path(layout.stage))
            if let face {
                let color = status.color
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
                ctx.stroke(line, with: .color(color.opacity(0.9)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                for p in [a, b] {
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(color))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Hosts the live preview layer at `cameraRect` (view top-left coordinates),
/// clipped to `mask`. The layer is the recorder session's own, so the
/// picture is the recorded one (same device, format and mirroring).
struct LivePreviewView: NSViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer?
    let cameraRect: CGRect
    let mask: CGPath

    func makeNSView(context: Context) -> LivePreviewNSView { LivePreviewNSView() }

    func updateNSView(_ view: LivePreviewNSView, context: Context) {
        view.set(layer: layer, cameraRect: cameraRect, mask: mask)
    }

    static func dismantleNSView(_ view: LivePreviewNSView, coordinator: ()) {
        view.set(layer: nil, cameraRect: .zero, mask: CGPath(rect: .zero, transform: nil))
    }
}

final class LivePreviewNSView: NSView {
    private var preview: AVCaptureVideoPreviewLayer?
    private var cameraRect: CGRect = .zero
    private var maskPath = CGPath(rect: .zero, transform: nil)
    private let maskLayer = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func set(layer newLayer: AVCaptureVideoPreviewLayer?, cameraRect: CGRect, mask: CGPath) {
        if newLayer !== preview {
            // Only let go of it if it is still ours: SwiftUI may already have
            // handed the same layer to a newer view.
            if let old = preview, old.superlayer === layer {
                old.mask = nil
                old.removeFromSuperlayer()
            }
            preview = newLayer
            if let newLayer {
                newLayer.removeFromSuperlayer()
                newLayer.videoGravity = .resize
                layer?.addSublayer(newLayer)
            }
        }
        self.cameraRect = cameraRect
        self.maskPath = mask
        needsLayout = true
        layoutPreview()
    }

    override func layout() {
        super.layout()
        layoutPreview()
    }

    /// Top-left (SwiftUI) → this layer's bottom-left geometry.
    private func layoutPreview() {
        guard let preview else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let h = bounds.height
        if cameraRect.width > 0, cameraRect.height > 0 {
            preview.frame = CGRect(x: cameraRect.minX, y: h - cameraRect.maxY, width: cameraRect.width, height: cameraRect.height)
        } else {
            preview.videoGravity = .resizeAspect
            preview.frame = bounds
        }
        // The mask lives in the preview layer's own coordinates.
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -preview.frame.minX, ty: h - preview.frame.minY)
        maskLayer.frame = preview.bounds
        maskLayer.path = maskPath.copy(using: &flip)
        preview.mask = maskLayer
    }
}

// MARK: - Window content

struct FramingStatusBadge: View {
    let advice: FramingAdvice
    var prominent = true
    var title: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(advice.status.color)
                .frame(width: prominent ? 12 : 8, height: prominent ? 12 : 8)
                .padding(.top, prominent ? 3 : 3)
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(title.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                }
                ForEach(Array(advice.hints.enumerated()), id: \.offset) { index, hint in
                    Text(hint)
                        .font(.system(size: prominent ? (index == 0 ? 15 : 13) : 10, weight: index == 0 ? .semibold : .regular))
                        .foregroundStyle(.white.opacity(index == 0 ? 1 : 0.8))
                        .lineLimit(prominent ? 2 : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Everything in the framing window. Pure view: it can be
/// snapshotted with `ImageRenderer` using still frames.
struct FramingAssistantView: View {
    @ObservedObject var monitor: FramingMonitor
    /// nil = live (the monitor's preview layer); a still for snapshots.
    var still: CGImage?
    @State var selected = 0
    @State var sensor = false

    private let cream = Color(red: 0.961, green: 0.929, blue: 0.847)

    var body: some View {
        let report = monitor.report
        let crops = report.crops
        let index = crops.isEmpty ? 0 : min(selected, crops.count - 1)
        let crop = crops.isEmpty ? nil : crops[index]
        VStack(spacing: 0) {
            header(report: report, crops: crops)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            ZStack(alignment: .bottomLeading) {
                FramingStage(
                    content: still.map { .still($0) } ?? .live(monitor.livePreview),
                    cameraSize: report.cameraSize == .zero ? CGSize(width: 1920, height: 1080) : report.cameraSize,
                    crop: crop, allCrops: crops, sensor: sensor, guides: true,
                    face: report.face, status: report.perCrop.indices.contains(index) ? report.perCrop[index].status : .unknown
                )
                if crops.count > 1, report.perCrop.indices.contains(index) {
                    FramingStatusBadge(advice: report.perCrop[index], prominent: false, title: "\(crop?.name ?? "") only")
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
                        .padding(12)
                }
            }
            .frame(minHeight: 300)

            if crops.count > 1 {
                strip(report: report, crops: crops, index: index)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }

            HStack(alignment: .top) {
                Text(crop.map { "\($0.name): \($0.spec.caption)" } ?? "Turn the camera on to check your framing.")
                    .font(.system(size: 11))
                    .foregroundStyle(cream.opacity(0.7))
                Spacer(minLength: 12)
                Text("Guides and hints are only on your screen, never in the recording.")
                    .font(.system(size: 11))
                    .foregroundStyle(cream.opacity(0.45))
                    .multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color(white: 0.10))
        .environment(\.colorScheme, .dark)
    }

    private func header(report: FramingReport, crops: [ResolvedFramingCrop]) -> some View {
        HStack(alignment: .center, spacing: 12) {
            FramingStatusBadge(advice: report.overall)
            Spacer(minLength: 8)
            if crops.count > 1 {
                Text("For all \(crops.count) layouts")
                    .font(.system(size: 11))
                    .foregroundStyle(cream.opacity(0.55))
            }
            Button {
                sensor.toggle()
            } label: {
                Label(sensor ? "Show the crop" : "Whole camera", systemImage: sensor ? "crop" : "viewfinder")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(cream.opacity(sensor ? 0.22 : 0.10), in: Capsule())
                    .foregroundStyle(cream)
            }
            .buttonStyle(.plain)
            .disabled(crops.first?.spec == .fullFrame)
            .opacity(crops.first?.spec == .fullFrame ? 0.35 : 1)
            .help("See the whole camera image, with what gets recorded outlined.")
        }
        .frame(minHeight: 44)
    }

    private func strip(report: FramingReport, crops: [ResolvedFramingCrop], index: Int) -> some View {
        HStack(spacing: 10) {
            ForEach(Array(crops.enumerated()), id: \.offset) { i, crop in
                let advice = report.perCrop.indices.contains(i) ? report.perCrop[i] : .waiting
                Button {
                    selected = i
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        FramingStage(
                            content: .still(monitor.thumbnail ?? still),
                            cameraSize: report.cameraSize, crop: crop, guides: false
                        )
                        .frame(height: 92)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        HStack(spacing: 5) {
                            Circle().fill(advice.status.color).frame(width: 8, height: 8)
                            Text(crop.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(cream)
                        }
                        Text(advice.hints.first ?? "")
                            .font(.system(size: 10))
                            .foregroundStyle(cream.opacity(0.7))
                            .lineLimit(2)
                            .frame(height: 26, alignment: .topLeading)
                    }
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(i == index ? cream.opacity(0.14) : Color.white.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(i == index ? cream.opacity(0.6) : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Window

/// A normal, resizable window (not a borderless panel: it is a tool you move
/// and size). Floating so it stays above the app you are about to record.
final class FramingWindow: NSWindow, NSWindowDelegate {
    var onClose: (() -> Void)?

    init(monitor: FramingMonitor) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        title = "Check framing"
        isReleasedWhenClosed = false
        level = .floating
        collectionBehavior = [.fullScreenAuxiliary]
        minSize = NSSize(width: 560, height: 520)
        contentView = NSHostingView(rootView: FramingAssistantView(monitor: monitor))
        delegate = self
        center()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
