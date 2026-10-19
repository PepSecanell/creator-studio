import AVFoundation
import Foundation

/// Cuts the last moments off a finished take.
///
/// When a take is stopped with the Bluetooth button, the last stretch of the
/// recording is the hand reaching for it. The press is the stop, so the file
/// ends a beat after the reach; this removes that beat. It works on the
/// finished file without re-encoding (passthrough), so it costs a second or
/// two and no quality.
enum TailTrim {

    /// How much to cut when the button stopped the take. You leave a short
    /// pause after the last word before pressing, so this takes the reach and
    /// the click, not the words.
    static let remoteStopSeconds: Double = 0.8

    /// How long the app waits after a press to see whether a second one
    /// follows (two presses = discard the take). The recording keeps running
    /// during that wait, so it is cut off as well.
    static let doublePressWindow: Double = 0.7

    /// What a button stop cuts in total: the reach plus the wait.
    static var remoteTotalSeconds: Double { remoteStopSeconds + doublePressWindow }

    struct Result {
        let trimmed: Double
        let newDuration: Double
    }

    /// Trims `seconds` off the end of `url`, in place. Takes shorter than
    /// 3 s + `seconds` are left alone (never turn a short take into nothing).
    @discardableResult
    static func trim(_ url: URL, seconds: Double) async -> Result? {
        guard seconds > 0 else { return nil }
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds,
              duration.isFinite, duration > seconds + 3 else { return nil }

        let newDuration = duration - seconds
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".tailtrim-\(UUID().uuidString).mov")
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            Diagnostics.log("tail trim: no export session for \(url.lastPathComponent)")
            return nil
        }
        session.outputURL = temp
        session.outputFileType = .mov
        session.timeRange = CMTimeRange(
            start: .zero, duration: CMTime(seconds: newDuration, preferredTimescale: 600)
        )
        session.shouldOptimizeForNetworkUse = false

        do {
            try await session.export(to: temp, as: .mov)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            Diagnostics.log(String(
                format: "tail trim: %@ %.1fs -> %.1fs (cut %.1fs)",
                url.lastPathComponent, duration, newDuration, seconds
            ))
            return Result(trimmed: seconds, newDuration: newDuration)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            Diagnostics.log(error: error, context: "tail trim \(url.lastPathComponent)")
            return nil
        }
    }
}
