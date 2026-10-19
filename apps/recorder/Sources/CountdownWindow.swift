import AppKit
import SwiftUI

/// The 3-2-1 before recording starts.
///
/// Like every other Studio Recorder window it is excluded from capture, so it
/// never lands in the take, it exists purely so there is a beat to get
/// composed before the first frame that counts.
@MainActor
final class CountdownWindow {

    private var panel: NSPanel?
    private let model = CountdownModel()

    func run(on screen: NSScreen, from start: Int) async {
        guard start > 0 else { return }

        let side: CGFloat = 260
        let panel = NSPanel(
            contentRect: NSRect(
                x: screen.frame.midX - side / 2,
                y: screen.frame.midY - side / 2,
                width: side,
                height: side
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: CountdownView(model: model))
        panel.orderFrontRegardless()
        self.panel = panel

        for value in stride(from: start, through: 1, by: -1) {
            model.value = value
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        panel.orderOut(nil)
        self.panel = nil
    }

    func cancel() {
        panel?.orderOut(nil)
        panel = nil
    }
}

@MainActor
final class CountdownModel: ObservableObject {
    @Published var value: Int = 3
}

private struct CountdownView: View {
    @ObservedObject var model: CountdownModel

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(red: 0.17, green: 0.08, blue: 0.03).opacity(0.82))
            Text("\(model.value)")
                .font(.system(size: 130, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(red: 0.96, green: 0.93, blue: 0.85))
                .contentTransition(.numericText(countsDown: true))
                .animation(.snappy(duration: 0.25), value: model.value)
        }
        .frame(width: 260, height: 260)
    }
}
