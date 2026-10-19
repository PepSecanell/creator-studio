import AVFoundation
import CoreImage
import CoreMedia
import Foundation

/// Short mode's finishing pass: take.mov → short.mov.
///
/// Cuts ONE fixed rectangle out of every frame (the same pixels for the whole
/// take, nothing tracks, pans or reframes), scales it to 1080x1920 with
/// Lanczos, and writes H.264 at a constant 30 fps with the take's mic audio.
///
/// - **Constant 30 fps.** The camera is pinned to 30 for Short takes, but a
///   capture can still arrive at 29.3 (a camera.mov at 88/3 fps). The
///   export lays down an exact 1/30 s grid and shows the source frame nearest
///   each tick, so players get a clean constant frame rate file whatever the capture did.
/// - **No colour management** in Core Image (NSNull working/output space): the
///   pixels are cropped and resampled, never converted, so skin tones come out
///   exactly as recorded. Tagged BT.709 like the camera file.
/// - **Audio** is handled like CameraOnlyExport: the first audio track
///   (the mic), AAC 48 kHz mono 256k, pumped concurrently with the video
///   (a writer fed one input at a time deadlocks, see CameraOnlyExport).
enum ShortExport {

    enum ExportError: LocalizedError {
        case noVideoTrack
        case badCrop
        case readerRefused(String)
        case writerRefused(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "The raw recording has no video track."
            case .badCrop: return "The 9:16 crop does not fit inside the recorded frame."
            case .readerRefused(let why): return "Could not read the raw recording: \(why)"
            case .writerRefused(let why): return "Could not write short.mov: \(why)"
            case .failed(let why): return "Short export failed: \(why)"
            }
        }
    }

    struct Request {
        var rawURL: URL
        /// Pixels of the raw frame, top-left origin (ShortFraming.cropRect).
        var crop: CGRect
        var outputSize: CGSize = ShortFraming.outputSize
        var frameRate: Int32 = ShortFraming.frameRate
        /// Export a slice instead of the whole take.
        var timeRange: CMTimeRange?
    }

    private static let aacSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 256_000
    ]

    /// The raw frame size as stored (what the crop must be measured against).
    static func frameSize(of url: URL) async throws -> CGSize {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }
        let size = try await track.load(.naturalSize)
        return CGSize(width: abs(size.width), height: abs(size.height))
    }

    @discardableResult
    static func export(_ request: Request, to outputURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: request.rawURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }
        let natural = try await videoTrack.load(.naturalSize)
        let frame = CGSize(width: abs(natural.width), height: abs(natural.height))
        let crop = request.crop.integral
        guard crop.width >= 2, crop.height >= 2,
              CGRect(origin: .zero, size: frame).contains(crop) else {
            throw ExportError.badCrop
        }
        let trackRange = try await videoTrack.load(.timeRange)
        let range = request.timeRange.map { $0.intersection(trackRange) } ?? trackRange
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        // Reader
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw ExportError.readerRefused("video track rejected") }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack = audioTracks.first {
            // Decoded straight to 48 kHz mono PCM, so a stereo source can't
            // trip the mono AAC input.
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
            }
        }

        // Writer
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let outW = Int(request.outputSize.width), outH = Int(request.outputSize.height)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outW,
            AVVideoHeightKey: outH,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoCompressionPropertiesKey: [
                // ~16 Mbps for 1080x1920@30: well above what video sites re-encode
                // to, so their pass is the only visible generation loss.
                AVVideoAverageBitRateKey: 16_000_000,
                AVVideoExpectedSourceFrameRateKey: Int(request.frameRate),
                AVVideoMaxKeyFrameIntervalKey: Int(request.frameRate) * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw ExportError.writerRefused("video track rejected") }
        writer.add(videoInput)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outW,
                kCVPixelBufferHeightKey as String: outH
            ]
        )

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard reader.startReading() else {
            throw ExportError.readerRefused(reader.error?.localizedDescription ?? "startReading refused")
        }
        guard writer.startWriting() else {
            throw ExportError.writerRefused(writer.error?.localizedDescription ?? "startWriting refused")
        }
        writer.startSession(atSourceTime: range.start)

        let renderer = CropRenderer(frame: frame, crop: crop, output: request.outputSize)
        let boundAudioInput = audioInput
        let boundAudioOutput = audioOutput
        let fps = request.frameRate

        async let videoDone: Int = runVideo(
            input: videoInput, output: videoOutput, adaptor: adaptor, renderer: renderer,
            start: range.start, end: range.end, fps: fps,
            queue: DispatchQueue(label: "io.github.creatorstudio.recorder.short.export.video")
        )
        async let audioDone: Void = {
            guard let boundAudioInput, let boundAudioOutput else { return }
            await SampleBufferPump().run(
                input: boundAudioInput, output: boundAudioOutput,
                queue: DispatchQueue(label: "io.github.creatorstudio.recorder.short.export.audio")
            )
        }()

        let frames = await videoDone
        _ = await audioDone
        await writer.finishWriting()

        if reader.status == .failed {
            throw ExportError.failed(reader.error?.localizedDescription ?? "reader failed")
        }
        guard writer.status == .completed else {
            throw ExportError.failed(writer.error?.localizedDescription ?? "writer status \(writer.status.rawValue)")
        }
        guard frames > 0 else { throw ExportError.failed("no frames were written") }
        return outputURL
    }

    /// Resamples the source onto an exact 1/fps grid: each tick shows the
    /// source frame nearest to it. Returns the number of frames written.
    private static func runVideo(
        input: AVAssetWriterInput,
        output: AVAssetReaderTrackOutput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        renderer: CropRenderer,
        start: CMTime, end: CMTime, fps: Int32,
        queue: DispatchQueue
    ) async -> Int {
        var finished = false
        var written = 0
        var current: CMSampleBuffer?
        var next: CMSampleBuffer?
        var sourceEnded = false
        let tick = 1.0 / Double(fps)
        let startSeconds = start.seconds
        let endSeconds = end.seconds

        func pull() -> CMSampleBuffer? {
            while let s = output.copyNextSampleBuffer() {
                if CMSampleBufferGetImageBuffer(s) != nil { return s }
            }
            return nil
        }
        func pts(_ s: CMSampleBuffer) -> Double { CMSampleBufferGetPresentationTimeStamp(s).seconds }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            func finish() {
                finished = true
                input.markAsFinished()
                continuation.resume(returning: written)
            }
            input.requestMediaDataWhenReady(on: queue) {
                if finished { return }
                while input.isReadyForMoreMediaData {
                    let t = startSeconds + Double(written) * tick
                    if current == nil {
                        current = pull()
                        if current == nil { finish(); return }
                    }
                    if next == nil, !sourceEnded {
                        next = pull()
                        if next == nil { sourceEnded = true }
                    }
                    // Advance to the source frame nearest this tick.
                    while let n = next, pts(n) <= t + tick / 2 {
                        current = n
                        next = pull()
                        if next == nil { sourceEnded = true }
                    }
                    if t >= endSeconds - tick / 4 { finish(); return }
                    if sourceEnded, next == nil, let c = current {
                        // Past the last frame's own duration: done.
                        let d = CMSampleBufferGetDuration(c)
                        let last = pts(c) + (d.isValid && d.seconds > 0 ? d.seconds : tick)
                        if t >= last - tick / 4 { finish(); return }
                    }
                    guard let c = current, let pixels = CMSampleBufferGetImageBuffer(c),
                          let pool = adaptor.pixelBufferPool else { finish(); return }
                    var out: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out)
                    guard let out else { finish(); return }
                    renderer.render(pixels, into: out)
                    let time = CMTime(value: CMTimeValue(written), timescale: fps) + start
                    if !adaptor.append(out, withPresentationTime: time) { finish(); return }
                    written += 1
                }
            }
        }
    }
}

/// One fixed crop + Lanczos scale. Shared by the export and previews.
final class CropRenderer: @unchecked Sendable {
    let frame: CGSize
    let crop: CGRect
    let output: CGSize
    private let context = CIContext(options: [
        .workingColorSpace: NSNull(),
        .outputColorSpace: NSNull(),
        .cacheIntermediates: false,
        .highQualityDownsample: true
    ])

    init(frame: CGSize, crop: CGRect, output: CGSize) {
        self.frame = frame
        self.crop = crop
        self.output = output
    }

    /// The crop, as Core Image sees it (bottom-left origin).
    private var ciCrop: CGRect {
        CGRect(x: crop.minX, y: frame.height - crop.maxY, width: crop.width, height: crop.height)
    }

    func image(from pixels: CVPixelBuffer) -> CIImage {
        let source = CIImage(cvPixelBuffer: pixels, options: [.colorSpace: NSNull()])
        let region = ciCrop
        // Clamp first so Lanczos never samples transparent pixels at the crop
        // edge (that would draw a dark hairline round the frame).
        let cut = source.cropped(to: region).clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
        let sy = output.height / region.height
        let sx = output.width / region.width
        let scaled = cut.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: sy,
            kCIInputAspectRatioKey: sx / sy
        ])
        return scaled.cropped(to: CGRect(origin: .zero, size: output))
    }

    func render(_ pixels: CVPixelBuffer, into out: CVPixelBuffer) {
        context.render(image(from: pixels), to: out, bounds: CGRect(origin: .zero, size: output), colorSpace: nil)
    }
}

/// The whole end of a Short take in one place: the 9:16 cut `short.mov`
/// that is written next to the full camera file `take.mov`.
enum ShortTake {
    struct Settings {
        /// The frame's position in take.mov's own orientation.
        var filePosition: ShortFraming.Position
        /// Where it sat in the live preview (mirrored when the preview is).
        var previewPosition: ShortFraming.Position
        var fileMirrored: Bool
        var previewMirrored: Bool
        var rotation: CGFloat = 0
        var camera: String = ""
        /// Seconds to cut off the end of short.mov (the reach for the button
        /// when a take was stopped with the Bluetooth clicker). take.mov keeps
        /// the whole recording.
        var tailTrim: Double = 0
    }

    struct Result {
        let shortURL: URL
        let crop: CGRect
        let feed: CGSize
        let duration: Double
    }

    /// Preview position → file position. The crop's travel is symmetric,
    /// so mirroring a fraction is just 1 - x.
    static func filePosition(previewPosition p: ShortFraming.Position, previewMirrored: Bool, fileMirrored: Bool) -> ShortFraming.Position {
        previewMirrored == fileMirrored ? p : ShortFraming.Position(x: 1 - p.x, y: p.y)
    }

    static func finish(folder: URL, rawURL: URL, settings: Settings) async throws -> Result {
        let feed = try await ShortExport.frameSize(of: rawURL)
        let crop = ShortFraming.cropRect(frame: feed, position: settings.filePosition)
        let fullDuration = (try? await AVURLAsset(url: rawURL).load(.duration).seconds) ?? 0
        // Never turn a very short take into nothing.
        let tailTrim = fullDuration > settings.tailTrim + 3 ? settings.tailTrim : 0
        let duration = fullDuration - tailTrim

        let shortURL = folder.appendingPathComponent("short.mov")
        var export = ShortExport.Request(rawURL: rawURL, crop: crop)
        if tailTrim > 0 {
            export.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
        }
        try await ShortExport.export(export, to: shortURL)
        return Result(shortURL: shortURL, crop: crop, feed: feed, duration: duration)
    }
}
