import AVFoundation
import CoreMedia
import Foundation

/// Records one camera-like device (webcam, Continuity Camera, or a
/// plugged-in iPhone's screen) to its own file, on the shared timeline.
///
/// Deliberately video-only. Audio already arrives through ScreenCaptureKit on
/// the same clock; pulling a second audio stream off the phone or webcam
/// would just be another thing to drift.
///
/// Uses AVCaptureVideoDataOutput plus an AVAssetWriter rather than the much
/// shorter AVCaptureMovieFileOutput, because only the data-output path lets
/// each sample be retimed through `RecordingClock`, which is what keeps this
/// file frame-aligned with the screen recording through pauses.
final class DeviceVideoRecorder: NSObject {

    enum RecorderError: LocalizedError {
        case cannotAddInput
        case cannotAddOutput
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .cannotAddInput:  return "This device could not be opened."
            case .cannotAddOutput: return "This device would not provide video frames."
            case .writerFailed(let why): return "Could not write the camera file: \(why)"
            }
        }
    }

    let session = AVCaptureSession()
    let previewLayer: AVCaptureVideoPreviewLayer

    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "io.github.creatorstudio.recorder.device")
    private let writerQueue = DispatchQueue(label: "io.github.creatorstudio.recorder.device.writer")

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var clock: RecordingClock?
    private var sessionOpen = false
    private var recording = false

    /// Stretches of the take where frames actually arrived. See `ClipSegment`
    /// without these an unplugged device freezes on its last frame.
    private var segments: [ClipSegment] = []
    private var segmentStart: Double = .nan
    private var lastSampleSeconds: Double = .nan

    /// Last timestamp written. A sample that does not advance is dropped:
    /// AVAssetWriter would otherwise fail the file permanently, and say so
    /// only at the very end. See the same guard in `ScreenRecorder`.
    private var lastWritten: CMTime = .invalid

    /// A break longer than this starts a new segment. Comfortably above any
    /// normal frame interval or dropped frame, comfortably below the time it
    /// takes a person to unplug a cable and plug it back in.
    private static let gapThreshold: Double = 0.5

    private(set) var outputURL: URL?
    private(set) var frameSize: CGSize = .zero

    /// True once a device has been handed to the capture session.
    private(set) var isAttached = false

    /// Fires on the writer queue once the true frame size is known, so the
    /// preview panel can correct its aspect ratio.
    var onFrameSizeKnown: ((CGSize) -> Void)?

    /// The newest frame off the camera, for the settings-panel layout
    /// preview (Studio) and the framing assistant.
    let frameTap = CameraFrameTap()

    /// Extra preview layers on this session (the framing window's big
    /// stage). Kept so mirroring stays in step with the file.
    private var extraPreviews: [AVCaptureVideoPreviewLayer] = []
    private var mirrored = false

    /// A second live preview of the same session: same device, same format,
    /// same mirroring as the recorded file.
    func makePreviewLayer() -> AVCaptureVideoPreviewLayer {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        extraPreviews.append(layer)
        applyMirroring(to: layer)
        return layer
    }

    private func applyMirroring(to layer: AVCaptureVideoPreviewLayer) {
        if let connection = layer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
    }

    override init() {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init()
        previewLayer.videoGravity = .resizeAspectFill
    }

    // MARK: - Format

    /// The frame rate a take is recorded at when the device can manage it.
    ///
    /// The edit pipeline masters at 60 (`render_pipeline.py`'s `FPS`) and the screen recorder has
    /// always captured at 60, so a 30fps camera is the one thing left holding the timeline down.
    static let targetFrameRate: Double = 60

    /// Ask the device for the best format it has, rather than accepting whatever AVFoundation
    /// happens to hand over.
    ///
    /// Without this, a camera that CAN do 60fps still delivers 30: nothing here ever set
    /// `activeFormat`, so the session picked a default. Measured on a MacBook, the
    /// MacBook Air camera tops out at 1920x1080@30, but an iPhone offers 1920x1080 and 1920x1440
    /// **at 60**, and it was being recorded at 30 purely by omission.
    ///
    /// Preference order: a format that hits `targetFrameRate` beats one that does not, then the
    /// widest frame at or under 1920 (the timeline is 1920x1080, a larger capture is downscaled,
    /// which costs bandwidth and buys nothing), then the aspect closest to the timeline's 16:9.
    ///
    /// That last rule is deliberate. An iPhone's best format by raw pixels is 1920x1440, which is
    /// 4:3, more sensor height, but it has to be cropped or fitted somewhere downstream, and a
    /// silent aspect mismatch is a worse bug than a slightly smaller frame. Matching the timeline
    /// exactly means the camera feed needs no reshaping at all.
    ///
    /// Every step is best-effort: a device that refuses configuration keeps the format it had, so
    /// this can only ever improve a take, never fail one.
    /// Studio screen takes crop a PORTRAIT face card (tall-left: 318x600 of 1920x1080, i.e. 1200px
    /// tall at the 4K export). A 1080-tall feed has to be UPSCALED into that card; the iPhone's
    /// 1920x1440 mode fills it with real pixels. Set by RecordingController only for screen takes
    /// in the Studio look. "Just me" and Classic still get the 16:9 format, because their
    /// timelines are 16:9 and a 4:3 feed there would need reshaping (low quality
    /// in earlier takes was the reason for the tall format).
    var preferTallFormat = false

    /// Re-pick the format on the attached device, e.g. right before a take starts, so a layout or
    /// mode change made after the camera was attached is honoured.
    func refreshFormat() {
        guard let input = session.inputs.first as? AVCaptureDeviceInput else { return }
        session.beginConfiguration()
        Self.selectBestFormat(on: input.device, preferTall: preferTallFormat)
        session.commitConfiguration()
        // Keep the known size in step, so the Studio bubble's crop follows
        // the new aspect before the first frame of a take is written.
        let dimensions = CMVideoFormatDescriptionGetDimensions(input.device.activeFormat.formatDescription)
        if dimensions.width > 0, dimensions.height > 0 {
            frameSize = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
        }
    }

    static func selectBestFormat(on device: AVCaptureDevice, preferTall: Bool = false) {
        func maxRate(_ f: AVCaptureDevice.Format) -> Double {
            f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        }
        func score(_ f: AVCaptureDevice.Format) -> (Int, Int, Int) {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let fast = maxRate(f) >= targetFrameRate - 0.5 ? 1 : 0
            // Frames wider than the timeline are a cost, not a gain: rank them below 1920.
            let width = Int(d.width) <= 1920 ? Int(d.width) : 1920 - Int(d.width)
            // Closest to the timeline's 16:9, so the feed needs no reshaping. Negated: nearer zero
            // wins, and 1920x1080 scores 0 while 1920x1440 scores -360.
            let squareness = -abs(Int(d.height) - Int(d.width) * 9 / 16)
            // Studio portrait card: more height is more face detail, prefer the tallest frame.
            return (fast, width, preferTall ? Int(d.height) : squareness)
        }

        guard let best = device.formats.max(by: { score($0) < score($1) }) else { return }
        guard (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }

        if best != device.activeFormat {
            device.activeFormat = best
        }
        // Pin the rate so the device cannot quietly drop to 30 in dim light. Capped to what this
        // format actually supports, asking for more than the range allows throws.
        let rate = min(targetFrameRate, maxRate(best))
        if rate > 0 {
            let duration = CMTime(value: 1, timescale: CMTimeScale(rate.rounded()))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        }
        let dim = CMVideoFormatDescriptionGetDimensions(best.formatDescription)
        print("camera format: \(dim.width)x\(dim.height) @\(Int(rate)), \(device.localizedName)")
    }

    // MARK: - Configuration

    /// Safe to call while the session is already running and a take is in
    /// progress, that is how an iPhone plugged in mid-recording joins.
    /// Frames start flowing into the writer that `startRecording` armed.
    func configure(device: AVCaptureDevice, mirrored: Bool) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        for existing in session.inputs { session.removeInput(existing) }
        for existing in session.outputs { session.removeOutput(existing) }
        isAttached = false

        Self.selectBestFormat(on: device, preferTall: preferTallFormat)

        let deviceInput = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(deviceInput) else { throw RecorderError.cannotAddInput }
        session.addInput(deviceInput)

        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw RecorderError.cannotAddOutput }
        session.addOutput(output)

        setMirrored(mirrored)

        let dimensions = CMVideoFormatDescriptionGetDimensions(
            device.activeFormat.formatDescription
        )
        frameSize = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
        isAttached = true
    }

    /// Drops the device without disturbing the writer, so a take survives the
    /// cable being pulled and can pick the device up again if it comes back.
    func detach() {
        guard isAttached else { return }
        session.beginConfiguration()
        for existing in session.inputs { session.removeInput(existing) }
        session.commitConfiguration()
        isAttached = false
        frameTap.store(nil)
    }

    /// Mirroring is baked into the recorded file, not just the preview, so
    /// what is seen while recording is what ends up in the video.
    func setMirrored(_ mirrored: Bool) {
        self.mirrored = mirrored
        for extra in extraPreviews { applyMirroring(to: extra) }
        for connection in output.connections where connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
        if let preview = previewLayer.connection, preview.isVideoMirroringSupported {
            preview.automaticallyAdjustsVideoMirroring = false
            preview.isVideoMirrored = mirrored
        }
    }

    func startPreview() {
        guard !session.isRunning else { return }
        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    func stopPreview() {
        guard session.isRunning else { return }
        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async {
            session.stopRunning()
        }
    }

    // MARK: - Recording

    /// Arms the recorder. The writer itself is created later, on the first
    /// frame that actually arrives.
    ///
    /// Deliberately NOT sized from `device.activeFormat` here: a connected
    /// iPhone (a CoreMediaIO DAL device) reports 0x0 until it is actually
    /// streaming, which silently produced a 2x2 pixel `iphone.mov`, the
    /// panel then blew those four pixels up to full size and looked like a
    /// grey smudge. Webcams report correctly, so only the phone showed it.
    ///
    /// Arming costs nothing and needs no device, which is the whole point:
    /// a take can start with no iPhone attached, and one plugged in ten
    /// minutes later still lands in the same file on the same clock.
    func startRecording(to url: URL, clock: RecordingClock) throws {
        try? FileManager.default.removeItem(at: url)

        writerQueue.sync {
            self.writer = nil
            self.input = nil
            self.clock = clock
            self.outputURL = url
            self.sessionOpen = false
            self.recording = true
            self.segments = []
            self.segmentStart = .nan
            self.lastSampleSeconds = .nan
            self.lastWritten = .invalid
        }
    }

    /// Records that a frame landed at `seconds`, coalescing runs of frames
    /// into segments. Runs on `writerQueue`.
    private func noteSample(at seconds: Double) {
        if segmentStart.isNaN {
            segmentStart = seconds
        } else if seconds - lastSampleSeconds > Self.gapThreshold {
            segments.append(ClipSegment(start: segmentStart, end: lastSampleSeconds))
            segmentStart = seconds
        }
        lastSampleSeconds = seconds
    }

    /// Runs on `writerQueue`.
    private func closeSegment() {
        guard !segmentStart.isNaN, !lastSampleSeconds.isNaN else { return }
        segments.append(ClipSegment(start: segmentStart, end: lastSampleSeconds))
        segmentStart = .nan
        lastSampleSeconds = .nan
    }

    /// When this device was actually delivering frames. Read after
    /// `stopRecording`.
    func recordedSegments() -> [ClipSegment] {
        writerQueue.sync { segments }
    }

    /// Builds the writer from the first real frame's dimensions.
    /// Runs on `writerQueue`.
    private func makeWriter(for sample: CMSampleBuffer, url: URL) -> Bool {
        guard let format = CMSampleBufferGetFormatDescription(sample) else { return false }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let width = Int(dimensions.width)
        let height = Int(dimensions.height)

        // A device still warming up can emit a degenerate frame; wait for a
        // real one rather than bake a broken size into the file.
        guard width >= 16, height >= 16 else { return false }

        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Int(Double(width * height) * 6.0),
                    AVVideoMaxKeyFrameIntervalKey: 60,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoAllowFrameReorderingKey: false
                ]
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { return false }
            writer.add(input)

            self.writer = writer
            self.input = input

            let size = CGSize(width: width, height: height)
            self.frameSize = size
            self.onFrameSizeKnown?(size)
            Diagnostics.log("device recorder writer created at \(width)x\(height)")
            return true
        } catch {
            Diagnostics.log(error: error, context: "device recorder writer")
            return false
        }
    }

    func stopRecording() async -> URL? {
        await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            writerQueue.async {
                guard self.recording, let writer = self.writer else {
                    self.recording = false
                    self.closeSegment()
                    continuation.resume(returning: nil)
                    return
                }
                self.recording = false
                self.closeSegment()

                guard self.sessionOpen, writer.status == .writing else {
                    // Nothing was ever written, no frames arrived in time.
                    self.writer = nil
                    self.input = nil
                    continuation.resume(returning: nil)
                    return
                }

                let url = self.outputURL
                self.input?.markAsFinished()
                writer.finishWriting {
                    continuation.resume(returning: writer.status == .completed ? url : nil)
                }
                self.writer = nil
                self.input = nil
            }
        }
    }
}

// MARK: - Sample delivery

extension DeviceVideoRecorder: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let sample = sampleBuffer
        if let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            frameTap.store(buffer)
        }

        writerQueue.async {
            guard self.recording, let clock = self.clock else { return }

            let pts = CMSampleBufferGetPresentationTimeStamp(sample)

            // The screen stream owns the timeline. Camera frames that arrive
            // before the first screen frame have nowhere to go, so drop them.
            guard let adjusted = clock.adjust(pts) else { return }

            // First usable frame defines the file's dimensions.
            if self.writer == nil {
                guard let url = self.outputURL,
                      self.makeWriter(for: sample, url: url) else { return }
            }
            guard let writer = self.writer, let input = self.input else { return }

            if !self.sessionOpen {
                guard writer.status == .unknown, writer.startWriting() else { return }
                writer.startSession(atSourceTime: .zero)
                self.sessionOpen = true
            }

            guard input.isReadyForMoreMediaData else { return }
            if self.lastWritten.isValid, adjusted <= self.lastWritten { return }

            let offset = CMTimeSubtract(pts, adjusted)
            guard let retimed = SampleBufferRetiming.retimed(sample, subtracting: offset) else { return }
            guard input.append(retimed) else {
                Diagnostics.log("device recorder append rejected at \(adjusted.seconds)s")
                return
            }
            self.lastWritten = adjusted
            self.noteSample(at: adjusted.seconds)
        }
    }
}
