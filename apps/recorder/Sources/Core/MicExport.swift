import AVFoundation
import Foundation

/// The reader and writer ends of one copy loop. Only the loop's own queue touches them.
private struct Pipe: @unchecked Sendable {
    let input: AVAssetWriterInput
    let output: AVAssetReaderTrackOutput
}

/// Small helpers that turn a finished recording into the files `take/v1` lists.
enum MicExport {

    enum ExportError: LocalizedError {
        case noAudio
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noAudio: return "The recording has no audio track."
            case .failed(let why): return "Could not write mic.wav: \(why)"
            }
        }
    }

    /// Writes the first audio track of `source` as 48 kHz, 16 bit, mono WAV.
    /// In every recording the first audio track is the microphone.
    static func writeWav(from source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ExportError.noAudio
        }
        try? FileManager.default.removeItem(at: destination)

        let pcm: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        do {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcm)
            guard reader.canAdd(output) else { throw ExportError.failed("the audio could not be read") }
            reader.add(output)

            let writer = try AVAssetWriter(outputURL: destination, fileType: .wav)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: pcm)
            guard writer.canAdd(input) else { throw ExportError.failed("the writer refused the audio") }
            writer.add(input)

            guard reader.startReading(), writer.startWriting() else {
                throw ExportError.failed(reader.error?.localizedDescription ?? writer.error?.localizedDescription ?? "unknown")
            }
            writer.startSession(atSourceTime: .zero)
            let pipe = Pipe(input: input, output: output)
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                let queue = DispatchQueue(label: "io.github.creatorstudio.recorder.micwav")
                pipe.input.requestMediaDataWhenReady(on: queue) {
                    while pipe.input.isReadyForMoreMediaData {
                        guard let buffer = pipe.output.copyNextSampleBuffer(), pipe.input.append(buffer) else {
                            pipe.input.markAsFinished()
                            done.resume()
                            return
                        }
                    }
                }
            }
            await writer.finishWriting()
            if writer.status != .completed {
                throw ExportError.failed(writer.error?.localizedDescription ?? "unknown")
            }
        } catch let error as ExportError {
            throw error
        } catch {
            throw ExportError.failed(error.localizedDescription)
        }
    }

    /// Duration in seconds and a rounded frame rate for the first video track.
    static func probe(_ url: URL) async -> (duration: Double, fps: Int) {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        var fps = 30
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let rate = try? await track.load(.nominalFrameRate), rate > 1 {
            fps = Int(rate.rounded())
        }
        return (duration.isFinite ? duration : 0, fps)
    }
}
