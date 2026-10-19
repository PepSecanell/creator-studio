import AVFoundation
import CoreMedia
import Foundation

/// Records just the camera and the microphone, no screen at all.
///
/// For a talking-head clip, there is no reason to ask for Screen Recording
/// permission or touch ScreenCaptureKit; this is a plain AVCaptureSession
/// with a camera input and a mic input, each with its own data output, both
/// retimed through the same `RecordingClock` used elsewhere so pause/resume
/// behaves identically to screen mode.
///
/// Writes the full rectangular frame, the shape crop and the transparent
/// background happen afterwards in `CameraOnlyExport`, not here, for the
/// same reason the screen bubble is composited after capture rather than
/// during it: masking during a live capture risks dropped frames under load,
/// and doing it offline means the shape can be changed without re-recording.
final class CameraOnlyRecorder: NSObject {

    enum RecorderError: LocalizedError {
        case cannotAddInput
        case cannotAddOutput
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .cannotAddInput:  return "The camera or microphone could not be opened."
            case .cannotAddOutput: return "The camera or microphone would not provide data."
            case .writerFailed(let why): return "Could not write the recording: \(why)"
            }
        }
    }

    let session = AVCaptureSession()
    let previewLayer: AVCaptureVideoPreviewLayer

    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let videoQueue = DispatchQueue(label: "io.github.creatorstudio.recorder.cameraonly.video")
    private let audioQueue = DispatchQueue(label: "io.github.creatorstudio.recorder.cameraonly.audio")
    private let writerQueue = DispatchQueue(label: "io.github.creatorstudio.recorder.cameraonly.writer")

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var clock: RecordingClock?
    private var sessionOpen = false
    private var recording = false

    /// Last timestamp written to each input. Same guard, and the same
    /// reasoning, as `ScreenRecorder.lastWritten`: one sample moving
    /// backwards fails the whole file, and it only says so at Stop.
    private var lastVideoWritten: CMTime = .invalid
    private var lastAudioWritten: CMTime = .invalid
    // Timebase gate: Continuity Camera's first ~2 frames can carry a foreign timebase.
    private var latestAudioPTS: CMTime = .invalid      // raw, updated even before recording
    private var gateCandidatePTS: CMTime = .invalid    // previous leading video frame
    private var gateSkipped = 0
    private var armedAt = Date()
    private var failureReported = false

    /// Size the camera format was configured for, until the first frame says otherwise.
    private var pendingSize: CGSize = .zero
    private var writtenSize: CGSize = .zero
    private(set) var outputURL: URL?
    private(set) var frameSize: CGSize = .zero

    var onFailure: ((Error) -> Void)?

    // MARK: Short mode

    /// Short takes: tallest landscape format pinned at 30 fps
    /// (`ShortFraming.selectFormat`), and a portrait-mounted Continuity Camera
    /// is turned upright via the rotation coordinator. Off = the Just me
    /// behaviour exactly as before (session preset `.high`, no rotation).
    var shortProfile = false
    /// Camera height cap chosen in the panel (nil = Best, the old behaviour).
    var maxHeight: Int?
    /// Degrees the frames are rotated to be upright (0 = landscape as
    /// delivered; 90/270 = the iPhone is mounted vertically → portrait frames).
    private(set) var rotationAngle: CGFloat = 0
    /// The device format's own size, before any rotation.
    private var formatSize: CGSize = .zero
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    /// Short: whether the recorded file is mirrored, independent of the
    /// preview. nil = same as the preview (Just me).
    var fileMirrorOverride: Bool?
    /// What `setMirrored` last applied to the file and to the preview.
    private(set) var fileMirrored = false
    private(set) var previewMirrored = false
    /// Short profile: the phone was turned (portrait ⇄ landscape) between takes.
    var onOrientationChange: ((CGSize) -> Void)?

    /// Size of the newest frame actually delivered (rotation included), if any.
    var deliveredFrameSize: CGSize? {
        guard let buffer = frameTap.latest() else { return nil }
        return CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
    }


    /// The newest camera frame (as recorded, mirroring included), for the
    /// framing assistant. A reference swap only, nothing is copied or
    /// drawn on the capture queue, and it never touches the writer.
    let frameTap = CameraFrameTap()

    override init() {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init()
        previewLayer.videoGravity = .resizeAspectFill
    }

    // MARK: - Configuration

    /// Camera only, no microphone: the framing assistant's live preview
    /// before a take ("Check framing" in Just me). Same session and preset as
    /// `configure`, so the picture is the one the take will record; Record
    /// re-runs `configure`, which adds the microphone.
    func configurePreview(camera: AVCaptureDevice, mirrored: Bool) throws {
        // Declared first so it runs LAST, after the commit below, once the
        // preview layer's connection exists.
        defer { finishOrientation(camera: camera) }
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        for existing in session.inputs { session.removeInput(existing) }
        for existing in session.outputs { session.removeOutput(existing) }

        let cameraInput = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(cameraInput) else { throw RecorderError.cannotAddInput }
        session.addInput(cameraInput)
        applyFormatProfile(camera: camera)

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(videoOutput) else { throw RecorderError.cannotAddOutput }
        session.addOutput(videoOutput)

        setMirrored(mirrored)

        let dimensions = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
        frameSize = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
    }

    func configure(camera: AVCaptureDevice, microphone: AVCaptureDevice, mirrored: Bool) throws {
        defer { finishOrientation(camera: camera) }
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        for existing in session.inputs { session.removeInput(existing) }
        for existing in session.outputs { session.removeOutput(existing) }

        let cameraInput = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(cameraInput) else { throw RecorderError.cannotAddInput }
        session.addInput(cameraInput)
        applyFormatProfile(camera: camera)

        let micInput = try AVCaptureDeviceInput(device: microphone)
        guard session.canAddInput(micInput) else { throw RecorderError.cannotAddInput }
        session.addInput(micInput)

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(videoOutput) else { throw RecorderError.cannotAddOutput }
        session.addOutput(videoOutput)

        // A wireless USB receiver can deliver 2-channel Float32 NON-interleaved PCM (stereo mode /
        // two transmitters). The mono AAC writer rejected those buffers (-11800 / OSStatus -12737) and every
        // camera-only take died. Ask Core Audio to hand us one fixed format whatever the mic sends:
        // 48 kHz, mono, 16-bit interleaved integer PCM, which the AAC writer always accepts.
        audioOutput.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
        guard session.canAddOutput(audioOutput) else { throw RecorderError.cannotAddOutput }
        session.addOutput(audioOutput)

        setMirrored(mirrored)

        let dimensions = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
        frameSize = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
    }

    /// Short: tallest landscape format at 30 fps. Otherwise the session's
    /// default preset, which is what Just me has always recorded with (and
    /// undoes a Short take's input-priority format on the same session).
    private func applyFormatProfile(camera: AVCaptureDevice) {
        if shortProfile {
            let chosen = ShortFraming.selectFormat(on: camera, maxHeight: maxHeight)
            Diagnostics.log("short format: \(chosen.map { "\(Int($0.width))x\(Int($0.height))@\(ShortFraming.frameRate)" } ?? "unchanged") on \(camera.localizedName)")
        } else if let maxHeight {
            let chosen = ShortFraming.selectFormat(on: camera, maxHeight: maxHeight)
            Diagnostics.log("just me format: \(chosen.map { "\(Int($0.width))x\(Int($0.height))" } ?? "unchanged") (cap \(maxHeight)p) on \(camera.localizedName)")
        } else if session.sessionPreset != .high, session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }
    }

    /// After the session is committed: Short turns a portrait-mounted phone
    /// upright (and keeps watching for a turn between takes); anything else
    /// stays exactly as delivered.
    private func finishOrientation(camera: AVCaptureDevice) {
        rotationObservation = nil
        let dims = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
        formatSize = CGSize(width: Int(dims.width), height: Int(dims.height))
        guard shortProfile else {
            rotationCoordinator = nil
            if rotationAngle != 0 {
                applyRotation(capture: 0, preview: 0)
            }
            return
        }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: camera, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        applyRotation(
            capture: coordinator.videoRotationAngleForHorizonLevelCapture,
            preview: coordinator.videoRotationAngleForHorizonLevelPreview
        )
        Diagnostics.log("short orientation: \(Int(rotationAngle))° → \(Int(frameSize.width))x\(Int(frameSize.height))")
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] coordinator, _ in
            DispatchQueue.main.async {
                guard let self, self.shortProfile else { return }
                // Never mid-take: the writer's size is fixed at Record.
                let busy = self.writerQueue.sync { self.recording }
                guard !busy else { return }
                self.applyRotation(
                    capture: coordinator.videoRotationAngleForHorizonLevelCapture,
                    preview: coordinator.videoRotationAngleForHorizonLevelPreview
                )
                Diagnostics.log("short orientation changed: \(Int(self.rotationAngle))°")
                self.onOrientationChange?(self.frameSize)
            }
        }
    }

    private func applyRotation(capture: CGFloat, preview: CGFloat) {
        var angle = capture.truncatingRemainder(dividingBy: 360)
        if angle < 0 { angle += 360 }
        var applied: CGFloat = 0
        for connection in videoOutput.connections where connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
            applied = angle
        }
        if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(preview) {
            connection.videoRotationAngle = preview
        }
        rotationAngle = applied
        let quarter = (applied == 90 || applied == 270)
        if formatSize.width > 0, formatSize.height > 0 {
            frameSize = quarter ? CGSize(width: formatSize.height, height: formatSize.width) : formatSize
        }
    }

    /// Mirroring is baked into the recorded file, not just the preview, so
    /// what is seen while recording is what ends up in the video.
    ///
    /// Short mode sets `fileMirrorOverride` so the FILE can differ
    /// from the preview: the preview stays a mirror (as in Just me) while the
    /// recorded Short is the true image by default. nil = file follows the
    /// preview, which is Just me's behaviour, unchanged.
    func setMirrored(_ mirrored: Bool) {
        let file = fileMirrorOverride ?? mirrored
        fileMirrored = file
        previewMirrored = mirrored
        for connection in videoOutput.connections where connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = file
        }
        if let preview = previewLayer.connection, preview.isVideoMirroringSupported {
            preview.automaticallyAdjustsVideoMirroring = false
            preview.isVideoMirrored = mirrored
        }
    }

    /// Short's Viewer view: show the preview in the FILE's orientation for a
    /// moment. Display only. `previewMirrored` (the space the frame is placed
    /// in) is unchanged, and the next `setMirrored` restores it.
    func setPreviewDisplayMirrored(_ mirrored: Bool) {
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
        frameTap.store(nil)
        guard session.isRunning else { return }
        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async {
            session.stopRunning()
        }
    }

    // MARK: - Recording

    func startRecording(to url: URL, clock: RecordingClock) throws {
        try? FileManager.default.removeItem(at: url)

        // The writer is NOT built here any more. Its size must be
        // the size of the pixel buffers the camera really delivers, and that
        // can differ from `activeFormat` (a Continuity Camera left on a Short
        // format, a preset renegotiation, a rotation). Building it lazily from
        // the first real frame makes a mismatch impossible.
        writerQueue.sync {
            self.lastVideoWritten = .invalid
            self.lastAudioWritten = .invalid
            self.gateCandidatePTS = .invalid
            self.gateSkipped = 0
            self.armedAt = Date()
            self.failureReported = false
            self.writer = nil
            self.videoInput = nil
            self.audioInput = nil
            self.pendingSize = CGSize(width: max(Int(frameSize.width), 2), height: max(Int(frameSize.height), 2))
            self.clock = clock
            self.outputURL = url
            self.sessionOpen = false
            self.recording = true
        }
        Diagnostics.log("camera-only armed: expected \(Int(frameSize.width))x\(Int(frameSize.height)) (format \(Int(formatSize.width))x\(Int(formatSize.height)), rotation \(Int(rotationAngle))deg) -> \(url.lastPathComponent)")
    }

    /// Builds and starts the writer from the first real frame. writerQueue only.
    private func openWriter(firstFrame buffer: CVPixelBuffer, at url: URL) throws -> AVAssetWriter {
        let rawW = CVPixelBufferGetWidth(buffer)
        let rawH = CVPixelBufferGetHeight(buffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(buffer)
        // H.264 wants even dimensions.
        let width = max(rawW & ~1, 2)
        let height = max(rawH & ~1, 2)
        Diagnostics.log("camera-only first frame: buffer \(rawW)x\(rawH) fmt \(Self.fourCC(pixelFormat)); expected \(Int(pendingSize.width))x\(Int(pendingSize.height)); writer \(width)x\(height)")
        if CGSize(width: rawW, height: rawH) != pendingSize {
            Diagnostics.log("camera-only NOTE: delivered size differs from the configured format size; using the delivered size")
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let videoSettings: [String: Any] = [
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
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw RecorderError.writerFailed("video track rejected")
        }
        writer.add(videoInput)

        // 256k mono (128k is not enough). Speech at 128k mono AAC is close to
        // transparent in ONE generation, but this file is the master and the audio is
        // re-encoded at least twice downstream. CameraOnlyExport, then Mixdown, and
        // AAC damage accumulates across generations. Spending bits on the first
        // encode is the cheapest quality in the whole chain: a 7-minute take grows
        // by about 6 MB.
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 256_000
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(audioInput) else {
            throw RecorderError.writerFailed("audio track rejected")
        }
        writer.add(audioInput)

        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.writtenSize = CGSize(width: width, height: height)
        return writer
    }

    private static func fourCC(_ code: OSType) -> String {
        let bytes = [UInt8((code >> 24) & 255), UInt8((code >> 16) & 255), UInt8((code >> 8) & 255), UInt8(code & 255)]
        return String(bytes: bytes, encoding: .macOSRoman) ?? "\(code)"
    }

    private static func describe(_ error: Error?) -> String {
        guard let error else { return "no writer error" }
        var parts: [String] = []
        var current: NSError? = error as NSError
        var depth = 0
        while let e = current, depth < 4 {
            parts.append("[\(e.domain) \(e.code)] \(e.localizedDescription) reason=\(e.localizedFailureReason ?? "-") userInfo=\(e.userInfo.filter { $0.key != NSUnderlyingErrorKey })")
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return parts.joined(separator: " <- underlying ")
    }

    /// Abort the take: stop writing, cancel, delete the stub. writerQueue only.
    private func failTake(_ message: String) {
        guard !failureReported else { return }
        failureReported = true
        recording = false
        writer?.cancelWriting()
        writer = nil
        videoInput = nil
        audioInput = nil
        if let url = outputURL { try? FileManager.default.removeItem(at: url) }
        Diagnostics.log("FATAL: camera-only \(message)")
        onFailure?(RecorderError.writerFailed(message))
    }

    func stopRecording() async -> URL? {
        await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            writerQueue.async {
                guard self.recording else {
                    continuation.resume(returning: nil)
                    return
                }
                self.recording = false

                guard self.sessionOpen, let writer = self.writer, writer.status == .writing else {
                    self.writer?.cancelWriting()
                    if let url = self.outputURL {
                        try? FileManager.default.removeItem(at: url)
                    }
                    self.writer = nil
                    self.videoInput = nil
                    self.audioInput = nil
                    continuation.resume(returning: nil)
                    return
                }

                let url = self.outputURL
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                writer.finishWriting {
                    continuation.resume(returning: writer.status == .completed ? url : nil)
                }
                self.writer = nil
                self.videoInput = nil
                self.audioInput = nil
            }
        }
    }
}

// MARK: - Sample delivery

extension CameraOnlyRecorder: AVCaptureVideoDataOutputSampleBufferDelegate,
                               AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let sample = sampleBuffer
        let isVideo = (output === videoOutput)
        if !isVideo { SpeechFollowHub.shared.feed(sampleBuffer) }   // follow-my-voice teleprompter
        if isVideo, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            frameTap.store(buffer)
        }

        writerQueue.async {
            if !isVideo { self.latestAudioPTS = CMSampleBufferGetPresentationTimeStamp(sample) }
            // The writer is opened lazily on the first video frame below, so it must NOT be required
            // here.
            guard self.recording,
                  let clock = self.clock else { return }

            let pts = CMSampleBufferGetPresentationTimeStamp(sample)

            // The camera stream owns the timeline here (there is no screen
            // stream in this mode), so it anchors the clock on its first
            // frame, mirrors how ScreenRecorder anchors on its first frame.
            if !self.sessionOpen {
                guard isVideo, let url = self.outputURL,
                      let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
                // Gate on a stable timebase before anchoring the clock.
                let audio = self.latestAudioPTS
                var stable = false
                var why = ""
                if audio.isValid {
                    let d = abs(CMTimeSubtract(pts, audio).seconds)
                    if d > 2 {
                        why = String(format: "pts %.3f vs audio %.3f", pts.seconds, audio.seconds)
                    } else if self.gateCandidatePTS.isValid, abs(CMTimeSubtract(pts, self.gateCandidatePTS).seconds) < 0.5 {
                        stable = true
                    } else {
                        why = "waiting for a second close frame"
                    }
                } else if Date().timeIntervalSince(self.armedAt) < 3 {
                    why = "no audio yet"
                } else if self.gateCandidatePTS.isValid, abs(CMTimeSubtract(pts, self.gateCandidatePTS).seconds) < 0.5 {
                    stable = true
                } else {
                    why = "no audio, waiting for a second close frame"
                }
                if !stable {
                    self.gateSkipped += 1
                    self.gateCandidatePTS = pts
                    Diagnostics.log("camera-only gate: skipped leading frame \(self.gateSkipped): \(why)")
                    return
                }
                if self.gateSkipped > 0 {
                    Diagnostics.log(String(format: "camera-only gate: skipped %d leading frames, anchoring at pts %.3f (audio %.3f)", self.gateSkipped, pts.seconds, audio.isValid ? audio.seconds : -1))
                }
                clock.startIfNeeded(at: pts)
                do {
                    let writer = try self.openWriter(firstFrame: pixels, at: url)
                    guard writer.startWriting() else {
                        self.failTake("startWriting refused, \(Self.describe(writer.error))")
                        return
                    }
                    writer.startSession(atSourceTime: .zero)
                    self.sessionOpen = true
                } catch {
                    self.failTake("could not open the writer, \(Self.describe(error))")
                    return
                }
            }
            guard let writer = self.writer else { return }

            // A frame of another size mid-take (phone turned, format change)
            // would be rejected by the encoder: say so, don't record garbage.
            if isVideo, let pixels = CMSampleBufferGetImageBuffer(sample) {
                let w = CVPixelBufferGetWidth(pixels) & ~1, h = CVPixelBufferGetHeight(pixels) & ~1
                if CGSize(width: w, height: h) != self.writtenSize {
                    self.failTake("frame size changed mid-take: \(w)x\(h) vs \(Int(self.writtenSize.width))x\(Int(self.writtenSize.height))")
                    return
                }
            }

            guard let adjusted = clock.adjust(pts, drivesElapsed: isVideo) else { return }

            let input = isVideo ? self.videoInput : self.audioInput
            guard let input, input.isReadyForMoreMediaData else { return }

            let previous = isVideo ? self.lastVideoWritten : self.lastAudioWritten
            let jump = previous.isValid ? adjusted.seconds - previous.seconds : adjusted.seconds
            if abs(jump) > 5 {
                Diagnostics.log(String(format: "FATAL TIMESTAMP JUMP: %@ pts %.3f raw, adjusted %.3f after %.3f", isVideo ? "video" : "audio", pts.seconds, adjusted.seconds, previous.isValid ? previous.seconds : 0))
                self.failTake(String(format: "%@ timestamps jumped %.1f s mid-take, stopped instead of writing a broken file", isVideo ? "camera" : "mic", jump))
                return
            }
            if previous.isValid, adjusted <= previous {
                Diagnostics.log(
                    String(
                        format: "dropped a non-advancing %@ sample (%.4fs after %.4fs)",
                        isVideo ? "camera" : "mic", adjusted.seconds, previous.seconds
                    )
                )
                return
            }

            let offset = CMTimeSubtract(pts, adjusted)
            guard let retimed = SampleBufferRetiming.retimed(sample, subtracting: offset) else { return }
            guard input.append(retimed) else {
                var detail = "\(isVideo ? "video" : "audio") append rejected at \(String(format: "%.3f", adjusted.seconds))s, writer status \(writer.status.rawValue), \(Self.describe(writer.error))"
                if let fd = CMSampleBufferGetFormatDescription(sample) {
                    detail += ", sample format \(fd)"
                }
                self.failTake(detail)
                return
            }
            if isVideo {
                self.lastVideoWritten = adjusted
            } else {
                self.lastAudioWritten = adjusted
            }
        }
    }
}
