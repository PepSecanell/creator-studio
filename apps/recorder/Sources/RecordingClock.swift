import CoreMedia
import Foundation

/// The single timeline every stream is written against.
///
/// ScreenCaptureKit and AVCaptureSession both timestamp their samples on the
/// host time clock, so screen frames, audio packets and camera frames arrive
/// on a shared timebase. Retiming them all through this one object is what
/// keeps the camera bubble locked to the screen, including across a pause,
/// where every stream must skip the exact same amount of time or they drift
/// apart for the rest of the take.
///
/// **The pause gap is measured in host time, deliberately.** It used to be
/// measured from sample timestamps: `pauseStartedAt` took whatever stream
/// happened to call `adjust` last, and the gap was closed by whatever stream
/// happened to call first after resuming. Those are almost never the same
/// stream, video, microphone and system audio arrive on three separate
/// queues at different rates. So the subtracted gap was measured between two
/// unrelated clocks' readings, and any stream whose own last sample sat later
/// than that reading resumed **behind where it left off**.
///
/// That is fatal. AVAssetWriter rejects a sample that moves backwards on an
/// input, marks the whole file failed, and says nothing until `finishWriting`
/// which is why a twenty-minute take could end in "Nothing was recorded"
/// with no warning along the way. Host time is stream-independent, so the
/// same gap now applies to all of them exactly.
final class RecordingClock {

    private let lock = NSLock()

    /// Timestamp of the very first screen frame. Anchors zero.
    private var firstPTS: CMTime = .invalid
    /// Total time spent paused, subtracted from every later sample.
    private var pausedTotal: CMTime = .zero
    private var pauseStartedAt: CMTime = .invalid
    /// Host time of the most recent resume. Samples captured before it belong
    /// to the paused stretch and are dropped rather than folded back in.
    private var resumedAt: CMTime = .invalid
    private var paused = false
    private var _elapsedSeconds: Double = 0

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return firstPTS.isValid
    }

    var isPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return paused
    }

    var elapsedSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return _elapsedSeconds
    }

    /// Seconds on the recording timeline *right now*, read from the host clock.
    ///
    /// `elapsedSeconds` only advances when a screen frame arrives. That was
    /// fine while the cursor was burned in, because moving it produced frames.
    /// With the cursor excluded from capture a still screen produces no frames
    /// at all, so pointer and click timestamps taken from `elapsedSeconds`
    /// would freeze while the hand moves. Same timebase as `adjust` (the screen
    /// samples are host-clock stamps), so the two agree to within a frame.
    /// nil before the first frame and while paused.
    var nowSeconds: Double? {
        lock.lock(); defer { lock.unlock() }
        guard firstPTS.isValid, !paused else { return nil }
        let adjusted = CMTimeSubtract(CMTimeSubtract(Self.hostTime(), firstPTS), pausedTotal)
        let seconds = adjusted.seconds
        return seconds.isFinite && seconds >= 0 ? seconds : nil
    }

    /// Anchors the timeline. Only the screen stream may call this.
    func startIfNeeded(at pts: CMTime) {
        lock.lock(); defer { lock.unlock() }
        guard !firstPTS.isValid else { return }
        firstPTS = pts
    }

    /// The timestamp this sample should be written at, or nil to drop it.
    ///
    /// - Parameter drivesElapsed: only the screen stream should pass true, so
    ///   the timer in the UI follows video frames rather than audio packets.
    func adjust(_ pts: CMTime, drivesElapsed: Bool = false) -> CMTime? {
        lock.lock(); defer { lock.unlock() }

        guard firstPTS.isValid, pts.isValid else { return nil }
        if paused { return nil }

        // Audio buffers are stamped at their start and delivered ~20ms later,
        // so a packet that began during the pause can still turn up after it.
        // Writing it would place it before the resume point.
        if resumedAt.isValid, pts < resumedAt { return nil }

        let adjusted = CMTimeSubtract(CMTimeSubtract(pts, firstPTS), pausedTotal)
        guard adjusted >= .zero else { return nil }

        if drivesElapsed {
            _elapsedSeconds = adjusted.seconds
        }
        return adjusted
    }

    func pause() {
        lock.lock(); defer { lock.unlock() }
        guard firstPTS.isValid, !paused else { return }
        paused = true
        pauseStartedAt = Self.hostTime()
    }

    func resume() {
        lock.lock(); defer { lock.unlock() }
        guard paused else { return }
        let now = Self.hostTime()
        if pauseStartedAt.isValid, now > pauseStartedAt {
            pausedTotal = CMTimeAdd(pausedTotal, CMTimeSubtract(now, pauseStartedAt))
        }
        pauseStartedAt = .invalid
        resumedAt = now
        paused = false
    }

    /// The clock every capture API on macOS stamps its samples against.
    private static func hostTime() -> CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }
}
