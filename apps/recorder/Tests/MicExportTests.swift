import AVFoundation
import XCTest

final class MicExportTests: XCTestCase {

    func testWritesA48kMonoWav() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-mic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("tone.m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2
        ]
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let frames = AVAudioFrameCount(44_100)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<2 {
            let samples = buffer.floatChannelData![channel]
            for i in 0..<Int(frames) { samples[i] = 0.3 * sinf(Float(i) * 0.06) }
        }
        do {
            let file = try AVAudioFile(forWriting: source, settings: settings)
            try file.write(from: buffer)
        }

        let destination = dir.appendingPathComponent("mic.wav")
        try await MicExport.writeWav(from: source, to: destination)
        let wav = try AVAudioFile(forReading: destination)
        XCTAssertEqual(wav.fileFormat.sampleRate, 48_000)
        XCTAssertEqual(wav.fileFormat.channelCount, 1)
        XCTAssertEqual(Double(wav.length) / 48_000, 1.0, accuracy: 0.1)
    }
}
