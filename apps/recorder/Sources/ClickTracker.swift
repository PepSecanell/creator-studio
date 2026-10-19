import AppKit
import Foundation

/// Records where and when the mouse was clicked during a take.
///
/// Clicks are logged as data, never burned into the pixels. The zoom and the
/// highlight ring are applied at export time from this log, which means both
/// can be retimed, softened or switched off entirely months later without
/// re-recording. Burning them in would be permanent.
///
/// Uses a global mouse monitor. Mouse events do not require Accessibility
/// permission on macOS (keyboard events would), so this costs the user no
/// extra prompt.
final class ClickTracker {

    struct Click: Codable {
        /// Seconds into the finished recording.
        let time: Double
        /// Normalised to the recorded display, origin bottom-left, matching
        /// Core Image's coordinate space so no flip is needed at export.
        let x: Double
        let y: Double
    }

    private var monitor: Any?
    private let lock = NSLock()
    private var recorded: [Click] = []

    var clicks: [Click] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    /// - Parameter captureRect: the part of the screen that actually ends up in
    ///   `screen.mov`, in global screen points. The recorder crops the display to
    ///   a centred 16:9 slice, so normalising to the whole screen put every
    ///   zoom and ring a few percent off vertically (26px at 2940
    ///   wide). Takes now normalise to this rect; the
    ///   pointer sidecar (`cursor-N.json`, `clickSpace: "capture"`) marks them.
    func start(clock: RecordingClock, screen: NSScreen, captureRect: CGRect? = nil) {
        stop()
        let frame = captureRect ?? screen.frame
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self else { return }
            guard clock.isRunning, !clock.isPaused else { return }

            let point = NSEvent.mouseLocation
            guard frame.contains(point) else { return }

            let click = Click(
                // Host-clock time: stays correct on a still screen, which
                // delivers no frames once the cursor is left out of capture.
                time: clock.nowSeconds ?? clock.elapsedSeconds,
                x: Double((point.x - frame.minX) / frame.width),
                y: Double((point.y - frame.minY) / frame.height)
            )
            self.lock.lock()
            self.recorded.append(click)
            self.lock.unlock()
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    func reset() {
        lock.lock()
        recorded.removeAll()
        lock.unlock()
    }

    /// Written next to the video so the edit can reuse it.
    func save(to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(clicks) else { return }
        try? data.write(to: url)
    }
}
