import AVFoundation
import Foundation
import Speech

/// Speech recognition for the teleprompter's "Follow my voice" mode.
///
/// The recording path is NOT changed: the mic sample buffers the recorders already receive are
/// handed to `feed(_:)`, which only copies a reference onto this hub's own queue (and does
/// nothing at all when follow mode is off). One `SFSpeechAudioBufferRecognitionRequest` is
/// kept alive; it restarts when the audio source changes (idle engine tap <-> recorder buffers)
/// and every ~45 s (Apple ends long tasks), so the transcript never goes stale.
///
/// While Studio Recorder is idle (rehearsing) a separate AVAudioEngine tap feeds the same
/// request; it is stopped the moment a take begins so it never competes with the capture.
final class SpeechFollowHub: @unchecked Sendable {

    static let shared = SpeechFollowHub()

    /// Running transcript of the current utterance (partials included). Delivered on the main queue.
    var onHeard: ((String) -> Void)?
    /// Human-readable state for the prompter's status line. Delivered on the main queue.
    var onStatus: ((String) -> Void)?

    private enum Source { case none, engine, recorder }

    private let queue = DispatchQueue(label: "io.github.creatorstudio.recorder.speechfollow")
    private let flag = NSLock()
    private var wantedFlag = false          // follow mode on (read from the recorder threads)

    // Everything below is touched on `queue` only.
    private var wanted = false
    private var busy = false                // a take is starting/recording
    private var source: Source = .none
    private var lastFeed = Date.distantPast
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var contextual: [String] = []
    private var rotateTimer: DispatchSourceTimer?
    private var consecutiveErrors = 0
    private var forceServer = false
    private static let serverUntilKey = "followServerOnlyUntil"
    private var authorized = false
    private let engine = AVAudioEngine()
    private var engineRunning = false
    private var heardAny = false

    private init() {}

    // MARK: - Control (any thread)

    /// Turn follow mode on/off. `words` are the script's distinctive words, passed to the
    /// recogniser as contextual strings so product and person names come out right.
    func setWanted(_ on: Bool, words: [String] = []) {
        flag.lock(); wantedFlag = on; flag.unlock()
        queue.async {
            self.contextual = Array(words.prefix(100))
            guard on != self.wanted || on else { return }
            self.wanted = on
            if on { self.beginIfPossible() } else { self.shutdown(status: "") }
        }
    }

    /// A take is starting (true) or fully over (false). The idle mic tap stops as soon as a
    /// take starts; recorder buffers take over through `feed(_:)`.
    func setBusy(_ isBusy: Bool) {
        queue.async {
            guard self.busy != isBusy else { return }
            self.busy = isBusy
            guard self.wanted else { return }
            if isBusy {
                self.stopEngine()
                if self.source == .engine { self.source = .none; self.restartRequest() }
            } else {
                self.source = .none
                self.beginIfPossible()
            }
        }
    }

    /// Mic sample buffers straight from the recorders. Cheap and non-blocking.
    func feed(_ sample: CMSampleBuffer) {
        flag.lock(); let on = wantedFlag; flag.unlock()
        guard on else { return }
        queue.async {
            guard self.wanted, self.authorized else { return }
            if self.source != .recorder {
                self.stopEngine()
                self.source = .recorder
                self.restartRequest()
            }
            self.lastFeed = Date()
            self.request?.appendAudioSampleBuffer(sample)
        }
    }

    // MARK: - Start / stop (queue)

    private func beginIfPossible() {
        guard wanted else { return }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            authorized = true
            startEngineIfIdle()
        case .notDetermined:
            status("Asking for speech recognition permission…")
            SFSpeechRecognizer.requestAuthorization { st in
                self.queue.async {
                    if st == .authorized { self.authorized = true; self.beginIfPossible() }
                    else { self.status("Speech recognition not allowed. Turn it on in System Settings > Privacy & Security > Speech Recognition.") }
                }
            }
        default:
            authorized = false
            status("Speech recognition not allowed. Turn it on in System Settings > Privacy & Security > Speech Recognition.")
        }
    }

    private func shutdown(status text: String) {
        stopEngine()
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        rotateTimer?.cancel(); rotateTimer = nil
        source = .none
        generation += 1
        status(text)
    }

    private func startEngineIfIdle() {
        guard wanted, authorized, !busy else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            status("Microphone not allowed for Studio Recorder.")
            return
        }
        guard !engineRunning else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { status("No microphone input available."); return }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.queue.async {
                guard self.source == .engine else { return }
                self.request?.append(buffer)
            }
        }
        engine.prepare()
        do {
            try engine.start()
            engineRunning = true
            source = .engine
            restartRequest()
        } catch {
            input.removeTap(onBus: 0)
            status("Could not start the microphone: \(error.localizedDescription)")
        }
    }

    private func stopEngine() {
        guard engineRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engineRunning = false
    }

    // MARK: - Recognition (queue)

    /// A fresh request + task. The previous request is ended only after the new one is in place.
    private func restartRequest() {
        guard wanted, authorized else { return }
        if recognizer == nil {
            recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) ?? SFSpeechRecognizer()
        }
        guard let rec = recognizer, rec.isAvailable else {
            status("Speech recognition isn't available right now.")
            return
        }
        let onDevice = Self.shouldUseOnDevice(rec, forceServer: forceServer)
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        req.contextualStrings = contextual
        req.requiresOnDeviceRecognition = onDevice
        req.addsPunctuation = false

        let oldTask = task, oldRequest = request
        request = req
        generation += 1
        let gen = generation
        task = rec.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            self.queue.async {
                guard gen == self.generation, self.wanted else { return }
                var ended = false
                if let result {
                    self.consecutiveErrors = 0
                    if !self.heardAny {
                        self.heardAny = true
                        Diagnostics.log("follow: first words heard (\(onDevice ? "on this Mac" : "online"))")
                    }
                    let text = result.bestTranscription.formattedString
                    DispatchQueue.main.async { self.onHeard?(text) }
                    // A final result closes the task: without a new one the prompter goes deaf
                    // until the 45 s rotation (found in the 10-17 end-to-end run).
                    if result.isFinal { ended = true }
                }
                if let error {
                    ended = true
                    self.consecutiveErrors += 1
                    let msg = error.localizedDescription
                    Diagnostics.log("follow: recognition ended (\(self.consecutiveErrors)): \(msg)")
                    let dictationOff = msg.localizedCaseInsensitiveContains("dictation") || msg.localizedCaseInsensitiveContains("disabled")
                    if onDevice && (dictationOff || self.consecutiveErrors >= 2) {
                        self.forceServer = true
                        UserDefaults.standard.set(Date().addingTimeInterval(86_400), forKey: Self.serverUntilKey)
                        Diagnostics.log("follow: on-device unavailable, going straight to server mode")
                    }
                }
                if ended {
                    let delay = self.consecutiveErrors == 0 ? 0.1 : min(2.0, 0.25 * Double(self.consecutiveErrors))
                    self.queue.asyncAfter(deadline: .now() + delay) {
                        guard gen == self.generation, self.wanted else { return }
                        self.restartRequest()
                    }
                }
            }
        }
        oldRequest?.endAudio()
        oldTask?.cancel()

        status(onDevice ? "Listening (on this Mac)" : "Listening (online)")
        scheduleRotation()
    }

    /// Decides on-device vs server before the first request, so a Mac with Dictation off does
    /// not burn failed attempts first. Dictation state is read from the system prefs.
    static func shouldUseOnDevice(_ rec: SFSpeechRecognizer, forceServer: Bool) -> Bool {
        guard rec.supportsOnDeviceRecognition, !forceServer else { return false }
        if let until = UserDefaults.standard.object(forKey: serverUntilKey) as? Date, until > Date() { return false }
        return dictationEnabled
    }

    /// System Settings > Keyboard > Dictation. Absent or 0 = off.
    static var dictationEnabled: Bool {
        let v = CFPreferencesCopyAppValue("Dictation Enabled" as CFString, "com.apple.assistant.support" as CFString)
        return (v as? NSNumber)?.intValue == 1
    }

    private func scheduleRotation() {
        rotateTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 45, repeating: 45)
        timer.setEventHandler { [weak self] in
            guard let self, self.wanted, self.source != .none else { return }
            self.restartRequest()
        }
        timer.resume()
        rotateTimer = timer
    }

    private func status(_ text: String) {
        DispatchQueue.main.async { self.onStatus?(text) }
    }
}

extension TeleprompterScript {
    /// Distinctive words of a script (long words, names, ALL CAPS), for the recogniser's
    /// contextual strings.
    static func contextualWords(_ text: String) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for raw in text.split(whereSeparator: { $0.isWhitespace }) {
            // [PINCH] / [TO YOU] / [VOICEOVER] are cues, never spoken: don't bias the recogniser to them.
            if raw.contains("[") || raw.contains("]") { continue }
            let w = raw.filter { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "\u{2019}" }
            guard w.count >= 6 || (w.count >= 2 && w.allSatisfy { $0.isUppercase }) else { continue }
            let key = w.lowercased()
            if seen.insert(key).inserted { out.append(String(w)) }
            if out.count >= 100 { break }
        }
        return out
    }
}
