import AppKit
import SwiftUI

/// A small floating crosshair you drag onto your camera lens (MacBook notch, an iPhone on a mount,
/// an external webcam). The prompter follows it while you drag; Done keeps the spot.
/// Excluded from recordings like every Studio Recorder window (the capture filter excludes
/// the whole app).
@MainActor
final class CameraSpotMarker {

    var onMove: ((CGPoint) -> Void)?
    var onDone: (() -> Void)?
    private var panel: NSPanel?
    private let model: TeleprompterModel
    private let start: CGPoint
    private var observer: NSObjectProtocol?
    /// The dot sits this far below the top of the window.
    private static let dotY: CGFloat = 22
    private static let size = NSSize(width: 250, height: 156)

    init(model: TeleprompterModel, start: CGPoint) {
        self.model = model
        self.start = start
    }

    func show() {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.contentView = NSHostingView(rootView: CameraSpotView(model: model) { [weak self] in self?.finish() })
        panel.setFrameOrigin(NSPoint(x: start.x - Self.size.width / 2, y: start.y + Self.dotY - Self.size.height))
        panel.orderFrontRegardless()
        self.panel = panel
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let p = self.panel else { return }
                self.onMove?(CGPoint(x: p.frame.midX, y: p.frame.maxY - Self.dotY))
            }
        }
    }

    func close() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func finish() {
        close()
        onDone?()
    }
}

struct CameraSpotView: View {
    @ObservedObject var model: TeleprompterModel
    let done: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(Color.red, lineWidth: 2).frame(width: 26, height: 26)
                Rectangle().fill(Color.red).frame(width: 1.5, height: 44)
                Rectangle().fill(Color.red).frame(width: 44, height: 1.5)
                Circle().fill(Color.red).frame(width: 4, height: 4)
            }
            .frame(height: 44)
            VStack(spacing: 6) {
                Text("Drag the cross onto your camera lens")
                    .font(.system(size: 12, weight: .semibold))
                Picker("", selection: $model.cameraSide) {
                    ForEach(CameraSide.allCases, id: \.self) { Text($0.label.replacingOccurrences(of: " the camera", with: "")).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 200)
                Button("Done", action: done)
                    .controlSize(.small)
            }
            .padding(.vertical, 8).padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.82)))
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
        }
        .frame(width: 250, height: 156, alignment: .top)
    }
}
