import AVFoundation
import CoreGraphics
import Foundation

/// Folds the raw capture into one finished file.
///
/// The raw .mov carries the mic and the system audio as two separate
/// tracks. Most players, and video sites, play only the first audio track,
/// so shipping it that way would silently drop half the sound.
///
/// Note for anyone tempted to simplify this: AVAssetExportSession over a
/// composition does NOT mix multiple audio tracks. It passes them through
/// as separate tracks. Verified by band-energy analysis, not by guessing.
/// AVAssetReaderAudioMixOutput is the API that actually sums them into one
/// PCM stream, so that is what this uses.
enum Mixdown {

    enum MixdownError: LocalizedError {
        case noVideoTrack
        case readerRefused(String)
        case writerRefused(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noVideoTrack:
                return "The raw recording has no video track."
            case .readerRefused(let why):
                return "Could not read the raw recording: \(why)"
            case .writerRefused(let why):
                return "Could not write the finished file: \(why)"
            case .failed(let why):
                return "Mixdown failed: \(why)"
            }
        }
    }

    /// Everything the finished file needs beyond the screen recording.
    struct Request {
        var rawURL: URL
        var cameraURL: URL?
        var phoneURL: URL?
        var bubbleRect: CGRect = .zero
        var bubbleCornerRadius: CGFloat = 0
        var bubbleShape: BubbleShape = .circle
        var bubbleTilt: CGFloat = 0
        var phoneRect: CGRect = .zero
        var phoneCornerRadius: CGFloat = 0
        var phoneShowsFrame = true
        /// When each overlay device was actually delivering frames.
        var cameraSegments: [ClipSegment] = []
        var phoneSegments: [ClipSegment] = []
        var zoom: ZoomTimeline = .none
        var clicks: [ClickTracker.Click] = []
        var showClickHighlight = true
        var frameRate: Int = 60

        /// Screen-share look. See `CompositorSettings.layout`.
        var layout: ScreenLayout = .classic
        var faceLayout: FaceLayout = .standard
        var cameraGrade = true
        var background: StudioBackground = .standard
        /// Studio only: frame the focused app window in the overview.
        var focus: FocusPath?
        /// Studio only: the dynamic layout (FACE/SPLIT/SCREEN/FOCUS over time).
        var layoutTimeline: LayoutTimeline = .fixed
        /// Studio only: export at this size instead of the capture's own
        /// (the 4K option). Nil = native. Classic always exports native.
        var outputSize: CGSize?
        /// Our own cursor. Only set when the system cursor is not in screen.mov.
        var pointer: PointerPath?
        /// Export only this stretch (previews). nil = whole take.
        var exportRange: CMTimeRange?

        /// True when the screen video can be copied through untouched.
        var isPassthrough: Bool {
            cameraURL == nil
                && phoneURL == nil
                && zoom.segments.isEmpty
                && (clicks.isEmpty || !showClickHighlight)
                && layout == .classic
                && pointer == nil
                && exportRange == nil
        }
    }

    private static let pcmSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false,
        AVLinearPCMIsBigEndianKey: false
    ]

    private static let aacSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 256_000
    ]

    // MARK: - Entry point

    @discardableResult
    static func compose(
        _ request: Request, to outputURL: URL, progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        if request.isPassthrough {
            return try await composePassthrough(raw: request.rawURL, to: outputURL, progress: progress)
        }
        return try await composeWithOverlays(request, to: outputURL, progress: progress)
    }

    // MARK: - Fast path: audio mix only, video copied

    /// No overlays, so the screen video is remuxed rather than re-encoded. /// finishes in seconds regardless of length, and loses no quality.
    private static func composePassthrough(
        raw rawURL: URL, to outputURL: URL, progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let asset = AVURLAsset(url: rawURL)

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw MixdownError.noVideoTrack
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        let reader = try AVAssetReader(asset: asset)

        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw MixdownError.readerRefused("video track rejected")
        }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(
                audioTracks: audioTracks, audioSettings: pcmSettings
            )
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
            }
        }

        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        let formatHint = try await videoTrack.load(.formatDescriptions).first
        let videoInput = AVAssetWriterInput(
            mediaType: .video, outputSettings: nil, sourceFormatHint: formatHint
        )
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = try await videoTrack.load(.preferredTransform)
        guard writer.canAdd(videoInput) else {
            throw MixdownError.writerRefused("video track rejected")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        try await run(reader: reader, writer: writer,
                      videoPair: (videoInput, videoOutput),
                      audioPair: pair(audioInput, audioOutput),
                      progress: progress, duration: try await asset.load(.duration))
        return outputURL
    }

    // MARK: - Overlay path: real compositing

    private static func composeWithOverlays(
        _ request: Request, to outputURL: URL, progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let rawAsset = AVURLAsset(url: request.rawURL)

        guard let screenSource = try await rawAsset.loadTracks(withMediaType: .video).first else {
            throw MixdownError.noVideoTrack
        }
        let screenDuration = try await rawAsset.load(.duration)
        let fullRange = CMTimeRange(start: .zero, duration: screenDuration)
        let naturalSize = try await screenSource.load(.naturalSize)
        let renderSize = request.layout == .studio ? (request.outputSize ?? naturalSize) : naturalSize

        let composition = AVMutableComposition()
        let settings = CompositorSettings()
        settings.renderSize = renderSize
        settings.bubbleRect = request.bubbleRect
        settings.bubbleCornerRadius = request.bubbleCornerRadius
        settings.bubbleShape = request.bubbleShape
        settings.bubbleTilt = request.bubbleTilt
        settings.phoneRect = request.phoneRect
        settings.phoneCornerRadius = request.phoneCornerRadius
        settings.phoneShowsFrame = request.phoneShowsFrame
        settings.zoom = request.zoom
        settings.clicks = request.showClickHighlight ? request.clicks : []
        settings.showClickHighlight = request.showClickHighlight
        settings.layout = request.layout
        settings.faceLayout = request.faceLayout
        settings.cameraGrade = request.cameraGrade
        settings.background = request.background
        settings.focus = request.focus
        settings.layoutTimeline = request.layoutTimeline
        settings.pointer = request.pointer

        // Screen
        guard let screenTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw MixdownError.failed("could not add the screen track")
        }
        try screenTrack.insertTimeRange(fullRange, of: screenSource, at: .zero)
        settings.screenTrackID = screenTrack.trackID

        // Overlay videos
        settings.cameraTrackID = try await addVideo(
            from: request.cameraURL, to: composition, limitedTo: screenDuration
        )
        settings.cameraSegments = request.cameraSegments

        settings.phoneTrackID = try await addVideo(
            from: request.phoneURL, to: composition, limitedTo: screenDuration
        )
        settings.phoneSegments = request.phoneSegments

        // Audio comes from the raw file untouched.
        for source in try await rawAsset.loadTracks(withMediaType: .audio) {
            guard let track = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }
            let sourceDuration = try await source.load(.timeRange).duration
            let range = CMTimeRange(
                start: .zero, duration: CMTimeMinimum(sourceDuration, screenDuration)
            )
            try? track.insertTimeRange(range, of: source, at: .zero)
        }

        // Video composition driven by our compositor.
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(
            value: 1, timescale: CMTimeScale(request.frameRate)
        )
        videoComposition.customVideoCompositorClass = StudioCompositor.self
        videoComposition.instructions = [
            StudioInstruction(timeRange: fullRange, settings: settings)
        ]

        // Reader
        let reader = try AVAssetReader(asset: composition)
        let videoTracks = composition.tracks(withMediaType: .video)
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        videoOutput.videoComposition = videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw MixdownError.readerRefused("composited video rejected")
        }
        reader.add(videoOutput)
        if let range = request.exportRange {
            reader.timeRange = CMTimeRangeGetIntersection(range, otherRange: fullRange)
        }

        let audioTracks = composition.tracks(withMediaType: .audio)
        var audioOutput: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(
                audioTracks: audioTracks, audioSettings: pcmSettings
            )
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
            }
        }

        // Writer, the composited video has to be encoded, there is no
        // passthrough once pixels change.
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        let width = Int(renderSize.width)
        let height = Int(renderSize.height)
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Int(Double(width * height) * 5.0),
                    AVVideoMaxKeyFrameIntervalKey: request.frameRate * 2,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoAllowFrameReorderingKey: false
                ]
            ]
        )
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw MixdownError.writerRefused("video track rejected")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        try await run(reader: reader, writer: writer,
                      videoPair: (videoInput, videoOutput),
                      audioPair: pair(audioInput, audioOutput),
                      sessionStart: request.exportRange.map {
                          CMTimeRangeGetIntersection($0, otherRange: fullRange).start
                      } ?? .zero,
                      progress: progress,
                      duration: request.exportRange.map { CMTimeRangeGetIntersection($0, otherRange: fullRange).duration } ?? screenDuration)
        return outputURL
    }

    /// Adds an overlay video at the point in the take where it was actually
    /// filmed, and returns its track ID.
    ///
    /// The offset matters. An iPhone plugged in ten minutes into a take
    /// produces a file whose first sample sits at ten minutes, not at zero. /// inserting it at zero would slide the whole clip to the front of the
    /// video and show the phone during the part where it was not connected.
    /// So the source's own time range is preserved rather than flattened.
    private static func addVideo(
        from url: URL?,
        to composition: AVMutableComposition,
        limitedTo duration: CMTime
    ) async throws -> CMPersistentTrackID {
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            return kCMPersistentTrackID_Invalid
        }
        let asset = AVURLAsset(url: url)
        guard let source = try await asset.loadTracks(withMediaType: .video).first else {
            return kCMPersistentTrackID_Invalid
        }

        let sourceRange = try await source.load(.timeRange)
        let start = CMTimeMaximum(sourceRange.start, .zero)
        let room = CMTimeSubtract(duration, start)
        guard room > .zero else { return kCMPersistentTrackID_Invalid }
        let take = CMTimeMinimum(sourceRange.duration, room)
        guard take > .zero else { return kCMPersistentTrackID_Invalid }

        guard let track = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            return kCMPersistentTrackID_Invalid
        }
        do {
            try track.insertTimeRange(
                CMTimeRange(start: start, duration: take), of: source, at: start
            )
        } catch {
            composition.removeTrack(track)
            return kCMPersistentTrackID_Invalid
        }
        return track.trackID
    }

    // MARK: - Pumping

    private static func pair(
        _ input: AVAssetWriterInput?,
        _ output: AVAssetReaderOutput?
    ) -> (AVAssetWriterInput, AVAssetReaderOutput)? {
        guard let input, let output else { return nil }
        return (input, output)
    }

    private static func run(
        reader: AVAssetReader,
        writer: AVAssetWriter,
        videoPair: (AVAssetWriterInput, AVAssetReaderOutput),
        audioPair: (AVAssetWriterInput, AVAssetReaderOutput)?,
        sessionStart: CMTime = .zero,
        progress: (@Sendable (Double) -> Void)? = nil,
        duration: CMTime = .invalid
    ) async throws {
        guard reader.startReading() else {
            throw MixdownError.readerRefused(
                reader.error?.localizedDescription ?? "startReading refused"
            )
        }
        guard writer.startWriting() else {
            throw MixdownError.writerRefused(
                writer.error?.localizedDescription ?? "startWriting refused"
            )
        }
        writer.startSession(atSourceTime: sessionStart)

        let videoPump = SampleBufferPump()
        let audioPump = SampleBufferPump()

        let total: Double = duration.isValid ? duration.seconds : 0
        let startSeconds: Double = sessionStart.seconds
        var report: (@Sendable (CMTime) -> Void)?
        if let progress, total > 0 {
            report = { (stamp: CMTime) -> Void in
                let fraction: Double = (stamp.seconds - startSeconds) / total
                progress(Swift.min(1.0, Swift.max(0.0, fraction)))
            }
        }
        async let videoDone: Void = videoPump.run(
            input: videoPair.0,
            output: videoPair.1,
            queue: DispatchQueue(label: "io.github.creatorstudio.recorder.mixdown.video"),
            onSample: report
        )
        async let audioDone: Void = {
            guard let audioPair else { return }
            await audioPump.run(
                input: audioPair.0,
                output: audioPair.1,
                queue: DispatchQueue(label: "io.github.creatorstudio.recorder.mixdown.audio")
            )
        }()

        _ = await videoDone
        _ = await audioDone

        await writer.finishWriting()

        if reader.status == .failed {
            throw MixdownError.failed(reader.error?.localizedDescription ?? "reader failed")
        }
        guard writer.status == .completed else {
            throw MixdownError.failed(
                writer.error?.localizedDescription ?? "writer status \(writer.status.rawValue)"
            )
        }
    }
}
