import AVFoundation

/// Drains one reader output into one writer input, unmodified.
///
/// Shared by Mixdown's audio passthrough and CameraOnlyExport's audio
/// passthrough, both need "copy every sample across, no transform" and
/// nothing more. `finished` is only ever touched on the serial queue handed
/// to `run`, which is what keeps the continuation from resuming twice.
final class SampleBufferPump {
    private var finished = false

    func run(
        input: AVAssetWriterInput,
        output: AVAssetReaderOutput,
        queue: DispatchQueue,
        onSample: (@Sendable (CMTime) -> Void)? = nil
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) { [self] in
                if finished { return }
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer() else {
                        finished = true
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    let stamp = CMSampleBufferGetPresentationTimeStamp(sample)
                    if !input.append(sample) {
                        finished = true
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    onSample?(stamp)
                }
            }
        }
    }
}
