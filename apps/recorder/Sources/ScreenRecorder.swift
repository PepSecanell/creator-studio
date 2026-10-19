import AVFoundation
import CoreMedia
import ScreenCaptureKit
import AppKit

/// Captures screen + microphone + system audio through a single
/// ScreenCaptureKit stream and writes them into one .mov.
///
/// Why one stream: SCStream (macOS 15+) delivers screen, system audio and
/// microphone off the same clock. Capturing the mic separately through
/// AVCaptureSession is what makes QuickTime hand you a video and a stray
/// .m4a that drift apart. Here every sample shares a timebase, so the
/// tracks cannot desync.
///
/// The raw file carries two separate audio tracks (mic, system). Mixdown
/// folds them into one at stop.
final class ScreenRecorder: NSObject {

    enum RecorderError: LocalizedError {
        case noDisplay
        case writerFailed(String)
        case screenPermissionStale
        case captureFailed(String)

        var errorDescription: String? {
            switch self {
            case .noDisplay:
                return "No display available to record."
            case .writerFailed(let why):
                return "Nothing was recorded, \(why)"
            case .screenPermissionStale:
                return "macOS is refusing screen access. Re-tick Studio Recorder in "
                    + "System Settings › Privacy & Security › Screen Recording, "
                    + "then quit and reopen the app."
            case .captureFailed(let why):
                return "Capture could not start: \(why)"
            }
        }
    }

    struct Options {
        var display: SCDisplay
        var captureMicrophone: Bool
        var captureSystemAudio: Bool
        /// Which physical microphone to record from. nil lets macOS pick,
        /// which silently follows whatever the system's current input
        /// device is, a Bluetooth headset takes over the moment it is
        /// connected, at markedly worse quality, with no on-screen sign.
        var microphoneDeviceID: String?
        var targetHeight: Int?   // nil = native
        var frameRate: Int = 60
        var showsCursor: Bool = true
    }

    // MARK: - State

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var systemInput: AVAssetWriterInput?

    /// Everything touching the writer happens here. SCStream delivers on its
    /// own queues, so without this the three sample types would race.
    private let writerQueue = DispatchQueue(label: "io.github.creatorstudio.recorder.writer")

    private let screenQueue = DispatchQueue(label: "io.github.creatorstudio.recorder.screen")
    private let micQueue = DispatchQueue(label: "io.github.creatorstudio.recorder.mic")
    private let systemQueue = DispatchQueue(label: "io.github.creatorstudio.recorder.system")

    /// Shared with the camera and phone recorders so all three land on the
    /// same timeline, including across pauses.
    private let clock: RecordingClock
    private var sessionOpen = false

    /// Last timestamp actually written to each input, keyed by stream type.
    ///
    /// AVAssetWriter fails the **entire file**, permanently, and silently
    /// until `finishWriting`, the moment one sample moves backwards on an
    /// input. A twenty-minute take then ends in "Nothing was recorded". The
    /// clock is careful not to let that happen, but nothing here is willing
    /// to bet a whole recording on the clock being right, so any sample that
    /// is not strictly ahead of the last one is dropped instead. Losing a
    /// frame is invisible; losing the take is not.
    private var lastWritten: [Int: CMTime] = [:]

    /// Reported once, not once per sample.
    private var failureReported = false

    /// Set the instant `stop()` is called, before `stream.stopCapture()` has
    /// even returned. SCStream's teardown can take several seconds, worse
    /// with mic/system audio capture on, and without this flag every frame
    /// that arrives during that teardown keeps getting appended, so the take
    /// grows a multi-second tail nobody asked for and Stop feels laggy. Once
    /// this is true, `handle` drops samples instead of writing them.
    private var stopRequested = false

    private(set) var rawURL: URL?
    private(set) var pixelSize: CGSize = .zero

    /// Called on the writer queue if capture dies mid-recording.
    var onFailure: ((Error) -> Void)?

    init(clock: RecordingClock) {
        self.clock = clock
        super.init()
    }

    // MARK: - Discovery

    static func availableDisplays() async throws -> [SCDisplay] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        return content.displays
    }

    // MARK: - Exclusions (own windows)

    private var filterDisplay: SCDisplay?
    private var filterTimer: Timer?

    static func makeFilter(content: SCShareableContent, display: SCDisplay) -> SCContentFilter {
        let ourBundleID = Bundle.main.bundleIdentifier
        let excluded = content.windows.filter { $0.owningApplication?.bundleIdentifier == ourBundleID }
        return SCContentFilter(display: display, excludingWindows: excluded)
    }

    private func startFilterRefresh() {
        DispatchQueue.main.async { [weak self] in
            self?.filterTimer?.invalidate()
            self?.filterTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self, let stream = self.stream, let display = self.filterDisplay else { return }
                Task {
                    guard let content = try? await SCShareableContent.excludingDesktopWindows(
                        false, onScreenWindowsOnly: true) else { return }
                    try? await stream.updateContentFilter(Self.makeFilter(content: content, display: display))
                }
            }
        }
    }

    private func stopFilterRefresh() {
        DispatchQueue.main.async { [weak self] in self?.filterTimer?.invalidate(); self?.filterTimer = nil }
    }

    // MARK: - Start

    func start(options: Options, rawURL url: URL) async throws {
        self.rawURL = url

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
        } catch {
            // This is what a stale Screen Recording grant looks like, and
            // replacing the app bundle is enough to stale it.
            Diagnostics.log(error: error, context: "SCShareableContent")
            throw RecorderError.screenPermissionStale
        }

        // Keep Studio Recorder's own windows out of the recording: the control
        // panel, the camera bubble, the phone panel, the countdown and the
        // teleprompter are all ours, so excluding the application covers the
        // lot. The bubble is composited back in at export instead, which is
        // what keeps it movable after the fact.
        // A window-based filter is the only way to exclude single windows, so ours are excluded
        // window by window and the list is refreshed every second during the take (the countdown,
        // bubble and phone panel open and close while recording).
        let filter = Self.makeFilter(content: content, display: options.display)
        self.filterDisplay = options.display

        let (pixelWidth, pixelHeight) = Self.outputSize(for: options)
        pixelSize = CGSize(width: pixelWidth, height: pixelHeight)

        let config = SCStreamConfiguration()
        config.sourceRect = Self.sourceRect(for: options.display)
        config.width = pixelWidth
        config.height = pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.frameRate))
        config.showsCursor = options.showsCursor
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 6
        config.capturesAudio = options.captureSystemAudio
        config.sampleRate = 48_000
        config.channelCount = 2
        // Never record our own UI sounds back into the take.
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = options.captureMicrophone
        if let microphoneDeviceID = options.microphoneDeviceID {
            config.microphoneCaptureDeviceID = microphoneDeviceID
        }

        try setUpWriter(url: url, width: pixelWidth, height: pixelHeight, options: options)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenQueue)
        if options.captureSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemQueue)
        }
        if options.captureMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: micQueue)
        }
        self.stream = stream

        do {
            try await stream.startCapture()
            startFilterRefresh()
        } catch {
            Diagnostics.log(error: error, context: "startCapture")
            self.stream = nil
            writer?.cancelWriting()
            writer = nil
            try? FileManager.default.removeItem(at: url)
            throw RecorderError.captureFailed(error.localizedDescription)
        }

        Diagnostics.log(
            "capture started \(pixelWidth)x\(pixelHeight) @\(options.frameRate) "
            + "mic:\(options.captureMicrophone) micDevice:\(options.microphoneDeviceID ?? "system default") "
            + "system:\(options.captureSystemAudio)"
        )
    }

    /// The 16:9 slice of the display to actually capture, in the display's own point
    /// coordinate space (matches `SCDisplay.width`/`.height`, before the Retina backing
    /// scale). Delivery is always 1920x1080, and many displays aren't 16:9, capturing
    /// the whole thing meant every video needed cream pillarbox bars bolted on in editing
    /// instead of ever just being full
    /// screen. Cropping here means there's nothing left to pad. Centered on both axes,
    /// which also reliably crops out the macOS menu bar / recording-indicator band along
    /// the top, that band is a few dozen points tall, well inside the vertical margin a
    /// centered crop removes even on a display that's only modestly off 16:9.
    static func sourceRect(for display: SCDisplay) -> CGRect {
        let dw = Double(display.width), dh = Double(display.height)
        let targetAspect = 16.0 / 9.0
        if dw / dh > targetAspect {
            let cw = dh * targetAspect
            return CGRect(x: (dw - cw) / 2, y: 0, width: cw, height: dh)
        } else {
            let ch = dw / targetAspect
            return CGRect(x: 0, y: (dh - ch) / 2, width: dw, height: ch)
        }
    }

    static func outputSize(for options: Options) -> (Int, Int) {
        let display = options.display
        let scale = Self.backingScale(for: display.displayID)
        let crop = Self.sourceRect(for: display)
        var width = Int((crop.width * scale).rounded())
        var height = Int((crop.height * scale).rounded())

        if let target = options.targetHeight, height > target {
            let ratio = Double(target) / Double(height)
            width = Int((Double(width) * ratio).rounded())
            height = target
        }

        // H.264 wants even dimensions.
        if width % 2 != 0 { width -= 1 }
        if height % 2 != 0 { height -= 1 }
        return (width, height)
    }

    private static func backingScale(for displayID: CGDirectDisplayID) -> Double {
        for screen in NSScreen.screens {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            if let number = screen.deviceDescription[key] as? NSNumber,
               number.uint32Value == displayID {
                return Double(screen.backingScaleFactor)
            }
        }
        return 2.0
    }

    private func setUpWriter(url: URL, width: Int, height: Int, options: Options) throws {
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        // HEVC (better quality per byte than H.264 at w*h*5). This file is the MASTER, it is zoomed up to
        // 2.2x and re-encoded at 4K later, so small text needs every bit it can get. HEVC at w*h*6
        // is roughly H.264 at w*h*10 in quality (~22 Mbps at 2560x1440) for ~60% of the size,
        // hardware-encoded on Apple Silicon. Disk: ~165 MB a minute.
        let bitrate = Int(Double(width * height) * 6.0)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalKey: options.frameRate * 2,
                AVVideoAllowFrameReorderingKey: false
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw RecorderError.writerFailed("video track rejected")
        }
        writer.add(videoInput)
        self.videoInput = videoInput

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000
        ]

        if options.captureMicrophone {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                self.micInput = input
            }
        }
        if options.captureSystemAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                self.systemInput = input
            }
        }

        self.writer = writer
    }

    // MARK: - Stop

    func stop() async throws -> URL {
        // Tear the OS stream down in the background rather than waiting on
        // it here. `stopCapture()` finishing is not what should gate the
        // take ending. Recorded content is frozen the instant `stopRequested`
        // flips below; the stream can take its time releasing hardware.
        let streamToStop = stream
        stream = nil
        stopFilterRefresh()
        Task.detached { try? await streamToStop?.stopCapture() }

        return try await withCheckedThrowingContinuation { continuation in
            writerQueue.async {
                // From this point on, any sample still in flight from the
                // stream is dropped instead of appended, see `handle`.
                self.stopRequested = true

                guard let writer = self.writer, let url = self.rawURL else {
                    continuation.resume(throwing: RecorderError.writerFailed("no active recording"))
                    return
                }
                guard self.sessionOpen, writer.status == .writing else {
                    // A half-written .mov has no moov atom and is unplayable.
                    // Leaving it on disk looks like a successful take that
                    // will not open, so bin it and say what actually happened.
                    let why = writer.error?.localizedDescription
                        ?? (self.sessionOpen
                            ? "the recorder stopped unexpectedly"
                            : "no frames ever arrived from the screen")
                    Diagnostics.log(
                        "stop: writer status \(writer.status.rawValue), sessionOpen "
                        + "\(self.sessionOpen), discarding partial file. \(why)"
                    )
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: url)
                    self.writer = nil
                    continuation.resume(throwing: RecorderError.writerFailed(why))
                    return
                }

                self.videoInput?.markAsFinished()
                self.micInput?.markAsFinished()
                self.systemInput?.markAsFinished()

                writer.finishWriting {
                    if writer.status == .completed {
                        continuation.resume(returning: url)
                    } else {
                        let why = writer.error?.localizedDescription ?? "unknown writer failure"
                        continuation.resume(throwing: RecorderError.writerFailed(why))
                    }
                }
                self.writer = nil
            }
        }
    }

}

// MARK: - SCStreamOutput

extension ScreenRecorder: SCStreamOutput {

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        // Screen frames arrive even when nothing changed; only complete
        // frames carry real pixels.
        if type == .screen, !Self.isCompleteFrame(sampleBuffer) { return }

        // Follow-my-voice teleprompter: a copy of the reference goes to the speech hub's own
        // queue (nothing happens unless follow mode is on). The recording path is untouched.
        if type == .microphone { SpeechFollowHub.shared.feed(sampleBuffer) }

        // Retain across the queue hop.
        let retained = sampleBuffer

        writerQueue.async {
            self.handle(retained, of: type)
        }
    }

    private static func isCompleteFrame(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sample, createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
            let info = attachments.first,
            let raw = info[.status] as? Int,
            let status = SCFrameStatus(rawValue: raw)
        else { return false }
        return status == .complete
    }

    /// Everything below runs on `writerQueue`.
    private func handle(_ sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let writer, !stopRequested else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isValid else { return }

        // The session opens on the first real video frame, so audio that
        // arrives before any pixels never anchors the timeline.
        if !sessionOpen {
            guard type == .screen else { return }
            guard writer.status == .unknown else { return }
            guard writer.startWriting() else {
                onFailure?(RecorderError.writerFailed(
                    writer.error?.localizedDescription ?? "startWriting refused"
                ))
                return
            }
            writer.startSession(atSourceTime: .zero)
            clock.startIfNeeded(at: pts)
            sessionOpen = true
        }

        guard let adjusted = clock.adjust(pts, drivesElapsed: type == .screen) else { return }

        let offset = CMTimeSubtract(pts, adjusted)
        guard let retimedSample = SampleBufferRetiming.retimed(sample, subtracting: offset) else { return }

        let input: AVAssetWriterInput?
        switch type {
        case .screen:     input = videoInput
        case .microphone: input = micInput
        case .audio:      input = systemInput
        @unknown default: input = nil
        }

        guard let input, input.isReadyForMoreMediaData else { return }

        // Never let time move backwards on an input, see `lastWritten`.
        let key = type.rawValue
        if let previous = lastWritten[key], adjusted <= previous {
            Diagnostics.log(
                String(
                    format: "dropped a non-advancing %@ sample (%.4fs after %.4fs)",
                    Self.name(of: type), adjusted.seconds, previous.seconds
                )
            )
            return
        }

        guard input.append(retimedSample) else {
            reportWriteFailure(on: type, at: adjusted)
            return
        }
        lastWritten[key] = adjusted
    }

    /// A rejected append means the writer is already in `.failed`, which is
    /// terminal, the file can no longer be closed. Say so immediately rather
    /// than letting the take run on for another twenty minutes and only
    /// breaking the news at Stop.
    private func reportWriteFailure(on type: SCStreamOutputType, at time: CMTime) {
        guard !failureReported else { return }
        failureReported = true
        let why = writer?.error?.localizedDescription ?? "the writer rejected a sample"
        Diagnostics.log(
            String(
                format: "FATAL: %@ append rejected at %.3fs, %@",
                Self.name(of: type), time.seconds, why
            )
        )
        onFailure?(RecorderError.writerFailed(why))
    }

    private static func name(of type: SCStreamOutputType) -> String {
        switch type {
        case .screen:     return "screen"
        case .microphone: return "microphone"
        case .audio:      return "system audio"
        @unknown default: return "unknown"
        }
    }
}

// MARK: - SCStreamDelegate

extension ScreenRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        writerQueue.async {
            self.onFailure?(error)
        }
    }
}
