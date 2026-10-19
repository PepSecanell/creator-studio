import Foundation

/// Append-only log at ~/Library/Logs/Studio Recorder.log
///
/// Exists because a failed take used to leave nothing behind but a corrupt
/// file: no crash report, no console output, nothing to diagnose from. Now
/// every start, stop and failure is on disk with a timestamp.
enum Diagnostics {

    private static let queue = DispatchQueue(label: "io.github.creatorstudio.recorder.log")

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static var logURL: URL {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        return logs.appendingPathComponent("Studio Recorder.log")
    }

    static func log(_ message: String) {
        let stamped = "\(formatter.string(from: Date()))  \(message)\n"
        queue.async {
            guard let data = stamped.data(using: .utf8) else { return }
            let url = logURL
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    static func log(error: Error, context: String) {
        let nsError = error as NSError
        log("ERROR [\(context)] \(error.localizedDescription) "
            + "(domain: \(nsError.domain), code: \(nsError.code))")
    }
}
