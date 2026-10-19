import AppKit
import AVFoundation
import Combine
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Owns the recording state machine and everything the UI binds to.
@MainActor
final class RecordingController: ObservableObject {

    enum Phase: Equatable {
        case idle
        case countingDown
        case preparing
        case recording
        case paused
        case finishing
        case finished(URL)
        case failed(String)

        var isActive: Bool { self == .recording || self == .paused }
        var isBusy: Bool {
            self == .countingDown || self == .preparing || self == .finishing
        }
    }

    enum Quality: String, CaseIterable, Identifiable {
        case p1080 = "1080p"
        case p1440 = "1440p"
        case native = "Native"

        var id: String { rawValue }

        /// nil means "record at the display's own pixel size".
        var targetHeight: Int? {
            switch self {
            case .p1080:  return 1080
            case .p1440:  return 1440
            case .native: return nil
            }
        }
    }

    /// What a take captures. Camera-only skips the screen entirely, no
    /// Screen Recording permission needed.
    enum CaptureMode: String, CaseIterable, Identifiable {
        case screen = "Screen"
        case cameraOnly = "Just me"
        /// Vertical 9:16 take for short-form video. Records on the Just me path;
        /// saves into takes/shorts/, never takes/long/.
        case short = "Short"

        var id: String { rawValue }

        /// Just me and Short both record camera + mic with no screen.
        var usesCameraOnlyRecorder: Bool { self == .cameraOnly || self == .short }
    }

    /// Camera resolution cap for Just me / Short. Best = what each
    /// mode always did (Just me: session preset .high; Short: tallest 30 fps
    /// landscape format up to 1920 wide). The others pin the tallest 30 fps
    /// format at or below that height, and are only offered when the selected
    /// camera really has a format that is lower than the best one.
    enum CameraQuality: String, CaseIterable, Identifiable {
        case best = "Best"
        case p1080 = "1080p"
        case p720 = "720p"

        var id: String { rawValue }
        var maxHeight: Int? {
            switch self {
            case .best:  return nil
            case .p1080: return 1080
            case .p720:  return 720
            }
        }

        /// Options the camera can actually deliver at 30 fps (landscape, up to 1920 wide).
        static func available(for device: AVCaptureDevice?) -> [CameraQuality] {
            guard let device else { return [.best] }
            let heights = Set(device.formats.compactMap { f -> Int? in
                let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                let ok = f.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30.5 && $0.maxFrameRate >= 29.5 }
                return (d.width >= d.height && d.width <= 1920 && ok) ? Int(d.height) : nil
            })
            let top = heights.max() ?? 0
            var options: [CameraQuality] = [.best]
            if heights.contains(1080) && top > 1080 { options.append(.p1080) }
            if heights.contains(720) && top > 720 { options.append(.p720) }
            return options
        }
    }

    // MARK: - Screen

    @Published var captureMode: CaptureMode = .screen {
        didSet {
            guard captureMode != oldValue else { return }
            captureModeChanged(from: oldValue)
        }
    }
    @Published private(set) var phase: Phase = .idle {
        didSet { SpeechFollowHub.shared.setBusy(phase.isActive || phase.isBusy) }
    }
    @Published private(set) var displays: [SCDisplay] = []
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published var captureMicrophone = true
    @Published var captureSystemAudio = true

    /// Every microphone macOS currently sees.
    @Published private(set) var microphones: [AVCaptureDevice] = []
    /// Always a concrete device, never left to "whatever macOS defaults
    /// to". That default silently follows the current system input, so
    /// putting on a Bluetooth headset mid-session switches the take to its
    /// mic without anything on screen saying so. Pinned to the Mac's own
    /// microphone the first time it is seen, in `refreshDevices`.
    @Published var selectedMicrophoneID: String? {
        didSet { saveModeSetting("mic", selectedMicrophoneID) }
    }
    /// True when the selected microphone is not the Mac's own. AirPods, a
    /// headset, a USB interface. Surfaced as a standing warning, not a
    /// one-time toast, because the whole failure mode is that nothing on
    /// screen said so.
    /// True when something BETTER than the current choice is plugged in right now.
    ///
    /// This used to warn whenever the mic was not the Mac's built-in, which made it
    /// fire on exactly the device you most want to be using. Note:
    /// the warning is about a *downgrade*, not about being external. A USB mic
    /// outranks the built-in array and should never be flagged; AirPods rank below
    /// it and always should, because macOS drops a Bluetooth input to the
    /// hands-free profile, mono, ~16 kHz, the moment it records through one.
    var usingWorseMicrophoneThanAvailable: Bool {
        guard let selectedMicrophoneID,
              let device = microphones.first(where: { $0.uniqueID == selectedMicrophoneID })
        else { return false }
        let best = microphones.map(DeviceDiscovery.microphoneRank).max() ?? 0
        return DeviceDiscovery.microphoneRank(device) < best
    }
    /// The input the app would pick on its own, named, so the warning can say
    /// what to switch to instead of only saying something is wrong.
    var bestMicrophoneName: String? { DeviceDiscovery.bestMicrophone()?.localizedName }

    /// Optional preferred microphone, by name. Used whenever it is plugged in, ahead of the
    /// best-ranked input and ahead of any mic remembered from an earlier session. Set it with
    /// `defaults write <bundle id> preferredMicName "<name>"`. Empty by default.
    static var preferredMicName: String? {
        let name = UserDefaults.standard.string(forKey: "preferredMicName")?.trimmingCharacters(in: .whitespaces)
        return (name?.isEmpty == false) ? name : nil
    }
    var preferredMicrophone: AVCaptureDevice? {
        guard let name = Self.preferredMicName else { return nil }
        return microphones.first { $0.localizedName.localizedCaseInsensitiveContains(name) }
    }
    /// True when the preferred mic is not plugged in and the take would use something else.
    var preferredMicMissing: Bool { Self.preferredMicName != nil && preferredMicrophone == nil && !microphones.isEmpty }
    private var preferredMicWasPresent = false
    var selectedMicrophoneName: String? {
        guard let selectedMicrophoneID else { return nil }
        return microphones.first { $0.uniqueID == selectedMicrophoneID }?.localizedName
    }
    @Published var quality: Quality = .native   // full panel pixels (2560 wide on the Air); was .p1440
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var hasScreenPermission = true
    @Published private(set) var micPermission: Permissions.State = .notAsked
    @Published private(set) var cameraPermission: Permissions.State = .notAsked
    @Published private(set) var destinationName: String = ""
    @Published private(set) var lastFinalURL: URL?

    /// nil = create a new numbered folder. Otherwise reuse this one, so
    /// several takes of the same video land together.
    @Published var destinationFolder: URL? { didSet { refreshDestinationName() } }

    // MARK: - Workspace

    let workspace: Workspace
    let brand: BrandInfo

    @Published private(set) var existingFolders: [URL] = []

    /// The folder and numbering of the running (or last) take.
    private var takePlan: TakePlan?
    private var takeStartedAt = Date()
    private var takeHandoff: Handoff?

    // MARK: - Camera bubble

    @Published private(set) var cameras: [AVCaptureDevice] = []
    @Published var selectedCameraID: String?
    @Published var cameraEnabled = false { didSet { cameraEnabledChanged() } }
    @Published var bubbleShape: BubbleShape = .circle { didSet { applyBubbleLayout() } }
    @Published var bubbleTilt: Double = 0 { didSet { applyBubbleLayout() } }
    @Published var bubbleSize: Double = 260 { didSet { applyBubbleLayout() } }
    @Published var mirrorCamera = true {
        didSet {
            cameraRecorder.setMirrored(mirrorCamera)
            cameraOnlyRecorder.setMirrored(mirrorCamera)
            applyShortViewerDisplay()
        }
    }

    /// Camera resolution cap for Just me and Short, saved separately per mode.
    @Published var cameraQuality: CameraQuality = .best {
        didSet {
            guard cameraQuality != oldValue else { return }
            saveModeSetting("cameraQuality", cameraQuality.rawValue)
            cameraOnlyRecorder.maxHeight = cameraQuality.maxHeight
            guard !phase.isActive, !phase.isBusy else { return }
            cameraOnlyPreviewCameraID = nil   // re-run the preview on the new format
            updateFramingRouting()
        }
    }
    var cameraQualityOptions: [CameraQuality] {
        CameraQuality.available(for: cameras.first(where: { $0.uniqueID == selectedCameraID }) ?? cameras.first)
    }

    // Per-mode settings: microphone and camera quality are remembered per capture mode.
    private var restoringModeSettings = false
    private var modeSettingsRestoredOnce = false
    private func modeKey(_ name: String) -> String {
        "modeSetting.\(name).\(captureMode.rawValue)"
    }
    private func saveModeSetting(_ name: String, _ value: String?) {
        guard !restoringModeSettings else { return }
        UserDefaults.standard.set(value, forKey: modeKey(name))
    }
    private func restoreModeSettings() {
        restoringModeSettings = true
        defer { restoringModeSettings = false }
        let d = UserDefaults.standard
        if let pm = preferredMicrophone {
            selectedMicrophoneID = pm.uniqueID          // the preferred mic, not whatever was saved last time
        } else if let id = d.string(forKey: modeKey("mic")), microphones.contains(where: { $0.uniqueID == id }) {
            selectedMicrophoneID = id
        }
        if captureMode.usesCameraOnlyRecorder {
            let q = d.string(forKey: modeKey("cameraQuality")).flatMap(CameraQuality.init(rawValue:)) ?? .best
            cameraQuality = cameraQualityOptions.contains(q) ? q : .best
            cameraOnlyRecorder.maxHeight = cameraQuality.maxHeight
        }
    }

    // MARK: - Short mode

    /// Where the fixed 9:16 window sits (fraction of its travel, 0.5 = centred).
    /// Chosen before Record, remembered between launches, frozen for a take.
    @Published var shortPosition: ShortFraming.Position = RecordingController.storedShortPosition() {
        didSet {
            guard shortPosition != oldValue else { return }
            UserDefaults.standard.set(shortPosition.x, forKey: Self.shortXKey)
            UserDefaults.standard.set(shortPosition.y, forKey: Self.shortYKey)
        }
    }
    @Published var shortSafeZones: Bool = (UserDefaults.standard.object(forKey: RecordingController.shortZonesKey) as? Bool) ?? true {
        didSet { UserDefaults.standard.set(shortSafeZones, forKey: Self.shortZonesKey) }
    }
    /// Eye-line + face-size guide, and the live coaching pill.
    /// On by default, it only ever draws over the preview, never the file.
    @Published var shortFramingGuide: Bool = (UserDefaults.standard.object(forKey: RecordingController.shortGuideKey) as? Bool) ?? true {
        didSet { UserDefaults.standard.set(shortFramingGuide, forKey: Self.shortGuideKey) }
    }
    /// The camera frame the Short crop is measured against (rotation included).
    @Published private(set) var shortFrameSize: CGSize = .zero
    /// The newest short.mov, for "Last take".
    @Published private(set) var lastShortURL: URL?
    /// Everything frozen when a Short take starts (position in the file's
    /// orientation, mirroring, script). Never changes mid-take.
    private var shortTakeSettings: ShortTake.Settings?
    private var shortWindow: ShortPreviewWindow?
    private var shortReplayWindow: ShortReplayWindow?

    /// Runs the same Vision analysis as `framing`, fed by the Short window's
    /// own camera-only session. A separate monitor, not a mode
    /// of `framing`: it needs its own wording (`ShortFramingHints`) and its
    /// specs never change while dragging the frame (`.short` reads the
    /// crop centred, always, see `FramingCropSpec.short`).
    let shortFraming: FramingMonitor = {
        let monitor = FramingMonitor()
        monitor.messageProvider = ShortFramingHints.message
        monitor.goodAdvice = FramingAdvice(status: .good, hints: [ShortFramingHints.good])
        return monitor
    }()
    /// Mirror the RECORDED Short too. Off by default: the preview
    /// still follows "Mirror me" like Just me, but the file is the true image,
    /// so text behind you reads the right way.
    @Published var shortMirrorFile: Bool = (UserDefaults.standard.object(forKey: RecordingController.shortMirrorFileKey) as? Bool) ?? false {
        didSet {
            UserDefaults.standard.set(shortMirrorFile, forKey: Self.shortMirrorFileKey)
            applyShortMirroring()
        }
    }

    // MARK: Handoff from the Studio app

    /// The request the Studio app handed over (`handoff/next_take.json` or
    /// `handoff/next_recording.json`), applied and still fresh. nil = free recording.
    @Published private(set) var handoff: Handoff?
    private let ledger = HandoffLedger()
    private var handoffWatch: AnyCancellable?
    /// What the handoff put in the teleprompter, so "Not this one" only
    /// clears it if the text has not been edited since.
    private var handoffLoadedText: String?
    /// The Short frame window is in Viewer view (shows the file's orientation).
    private var shortViewerView = false

    /// The handoff, but only while it is the destination: if another video folder
    /// is picked the banner would claim a video the takes are not going into.
    var activeHandoff: Handoff? {
        guard let handoff else { return nil }
        switch handoff.kind {
        case .short:
            return captureMode == .short ? handoff : nil
        case .long:
            guard captureMode != .short, let folder = destinationFolder, let out = handoff.outDir,
                  folder.standardizedFileURL.path == TakePlanner.videoFolder(of: out).standardizedFileURL.path
            else { return nil }
            return handoff
        }
    }

    private static let shortXKey = "shortCropX"
    private static let shortYKey = "shortCropY"
    private static let shortZonesKey = "shortSafeZones"
    private static let shortGuideKey = "shortFramingGuide"
    private static let shortMirrorFileKey = "shortMirrorFile"

    private static func storedShortPosition() -> ShortFraming.Position {
        let d = UserDefaults.standard
        let x = d.object(forKey: shortXKey) as? Double ?? 0.5
        let y = d.object(forKey: shortYKey) as? Double ?? 0.5
        return ShortFraming.Position(x: x, y: y).clamped
    }

    var shortPreviewLayer: AVCaptureVideoPreviewLayer { cameraOnlyRecorder.previewLayer }
    /// The crop can only be moved between takes.
    var shortCropLocked: Bool { phase.isActive || phase.isBusy }
    var isShortWindowOpen: Bool { shortWindow != nil }
    /// "takes/shorts/2026-10-19-w42-03-take-2": where the next Short take lands.
    var shortDestinationName: String { destinationName }
    /// The request shown in the Short frame header: the take's own while
    /// recording, otherwise the one the next take will use.
    var shortHeaderHandoff: Handoff? {
        (phase.isActive || phase.isBusy) ? takeHandoff : activeHandoff
    }

    // MARK: - iPhone

    @Published private(set) var phones: [AVCaptureDevice] = []
    @Published var selectedPhoneID: String?
    /// Armed, not "connected". The iPhone may be plugged in later, even
    /// after Record has been pressed, and it still joins the take.
    @Published var phoneEnabled = false { didSet { phoneEnabledChanged() } }
    /// Armed but nothing plugged in yet.
    @Published private(set) var phoneWaiting = false
    @Published var phoneHeight: Double = 460 { didSet { applyPhoneLayout() } }
    @Published var phoneShowsFrame = true {
        didSet { phoneWindow?.setPhoneFrame(phoneShowsFrame) }
    }

    // MARK: - Polish

    /// When the export pushes in. Smart (default) = rare, meaningful zooms
    /// plus the hotkeys; the old every-click policy is never offered here
    /// (it has to zoom in when it's needed, not always).
    @Published var zoomMode: ZoomMode = RecordingController.storedZoomMode() {
        didSet { UserDefaults.standard.set(zoomMode.rawValue, forKey: Self.zoomModeKey) }
    }
    /// Upper bound of the adaptive zoom (Smart fits 1.5 to 2.2x to the region).
    @Published var zoomAmount: Double = 2.2
    /// "Zoom here" / "zoom out" hotkey presses in the current take.
    @Published private(set) var zoomMarkCount = 0
    @Published var clickHighlight = true

    // MARK: - Screen-share look (persisted)

    /// Studio = framed window on the lit room + face card in a fixed slot.
    /// Classic = the full-bleed look, kept so nothing is lost.
    @Published var screenLayout: ScreenLayout = RecordingController.storedLayout() {
        didSet {
            UserDefaults.standard.set(screenLayout.rawValue, forKey: Self.layoutKey)
            guard screenLayout != oldValue else { return }
            refreshCameraFormatForLayout()
            applyBubbleLayout(reanchor: true)
        }
    }
    /// Which face-card slot the Studio layout uses. Chosen per recording.
    @Published var faceLayout: FaceLayout = RecordingController.storedFaceLayout() {
        didSet {
            UserDefaults.standard.set(faceLayout.rawValue, forKey: Self.faceLayoutKey)
            guard faceLayout != oldValue else { return }
            applyBubbleLayout(reanchor: true)
        }
    }
    /// Draw our own large, smoothed cursor. The system cursor is only left
    /// out of the *capture*; it is never hidden or changed on screen.
    @Published var ownCursor: Bool = UserDefaults.standard.object(forKey: RecordingController.ownCursorKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(ownCursor, forKey: Self.ownCursorKey) }
    }
    /// Warm, slightly darker grade on the face card (Studio only).
    @Published var cameraGrade: Bool = UserDefaults.standard.object(forKey: RecordingController.cameraGradeKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(cameraGrade, forKey: Self.cameraGradeKey) }
    }

    /// Studio background. First launch = `StudioBackground.standard`.
    @Published var studioBackground: StudioBackground = RecordingController.storedBackground() {
        didSet {
            UserDefaults.standard.set(studioBackground.rawValue, forKey: Self.backgroundKey)
            // Dark room and the light presets place the card differently.
            guard studioBackground != oldValue else { return }
            applyBubbleLayout(reanchor: studioBackground.isLight != oldValue.isLight)
        }
    }
    /// Frame only the focused app window in the overview (plan A8). Off by
    /// default until proven on real takes; the window log is always recorded,
    /// so any take can be re-exported with it on.
    @Published var frameFocusedWindow: Bool = UserDefaults.standard.bool(forKey: RecordingController.focusWindowKey) {
        didSet { UserDefaults.standard.set(frameFocusedWindow, forKey: Self.focusWindowKey) }
    }
    /// Dynamic (default) = the Studio layout moves between FACE / SPLIT /
    /// SCREEN / FOCUS from the take's own signals; Fixed = one
    /// layout for the whole take, exactly as before. Light backgrounds only.
    @Published var layoutMode: LayoutMode = RecordingController.storedLayoutMode() {
        didSet { UserDefaults.standard.set(layoutMode.rawValue, forKey: Self.layoutModeKey) }
    }
    /// Studio export at 3840x2160 when the capture is at least 2560 wide.
    @Published var export4K: Bool = (UserDefaults.standard.object(forKey: RecordingController.export4KKey) as? Bool) ?? true {   // default ON: video sites give 4K uploads a far better codec and bitrate
        didSet { UserDefaults.standard.set(export4K, forKey: Self.export4KKey) }
    }

    private static let zoomModeKey = "zoomMode"
    private static let backgroundKey = "studioBackground"
    private static let focusWindowKey = "frameFocusedWindow"
    private static let export4KKey = "export4K"
    private static let layoutKey = "screenLayout"
    private static let faceLayoutKey = "faceLayout"
    private static let ownCursorKey = "ownCursor"
    private static let cameraGradeKey = "cameraGrade"
    private static let layoutModeKey = "layoutMode"

    private static func storedLayout() -> ScreenLayout {
        UserDefaults.standard.string(forKey: layoutKey).flatMap(ScreenLayout.init(rawValue:)) ?? .studio
    }
    private static func storedZoomMode() -> ZoomMode {
        // `.everyClick` is never restored as a default, even if stored.
        let mode = UserDefaults.standard.string(forKey: zoomModeKey).flatMap(ZoomMode.init(rawValue:)) ?? .smart
        return mode == .everyClick ? .smart : mode
    }
    private static func storedBackground() -> StudioBackground {
        UserDefaults.standard.string(forKey: backgroundKey).flatMap(StudioBackground.init(rawValue:)) ?? .standard
    }
    private static func storedLayoutMode() -> LayoutMode {
        UserDefaults.standard.string(forKey: layoutModeKey).flatMap(LayoutMode.init(rawValue:)) ?? .standard
    }
    private static func storedFaceLayout() -> FaceLayout {
        UserDefaults.standard.string(forKey: faceLayoutKey).flatMap(FaceLayout.init(rawValue:)) ?? .standard
    }
    @Published var countdownSeconds: Int = 3
    @Published var teleprompterVisible = false

    // MARK: - Bluetooth start/stop button

    /// The selfie clicker that starts and stops a take from across the room.
    @Published private(set) var remoteStatus: RemoteButton.Status = RemoteButton.shared.status
    /// True from the moment the button asks for a stop until that stop reads it.
    /// The tail trim only applies to a button stop: with ⌘R there is no
    /// reaching moment to cut that we can know the length of.
    private var stopCameFromRemote = false
    /// A button press waiting to see if a second one follows (then it is a discard).
    private var pendingRemoteStop: Task<Void, Never>?

    // MARK: - Framing assistant

    /// Show the framing traffic light + one hint on the camera bubble.
    @Published var framingHintsOnBubble: Bool = (UserDefaults.standard.object(forKey: RecordingController.framingPillKey) as? Bool) ?? true {
        didSet { UserDefaults.standard.set(framingHintsOnBubble, forKey: Self.framingPillKey) }
    }
    private static let framingPillKey = "framingHintsOnBubble"
    /// Runs the face analysis and holds the current advice.
    let framing = FramingMonitor()
    private var framingWindow: FramingWindow?
    /// A second preview layer on the bubble camera's session, for the window.
    private var framingCameraPreview: AVCaptureVideoPreviewLayer?
    /// Just me: the camera the window's preview-only session was set up
    /// with. nil = not running for the window (off, or a take owns it).
    private var cameraOnlyPreviewCameraID: String?
    /// Whether that preview session was set up with the Short profile.
    private var cameraOnlyPreviewShort = false
    private var framingSinks: [AnyCancellable] = []

    // MARK: - Internals

    private var clock = RecordingClock()
    private var screenRecorder: ScreenRecorder?
    private let cameraRecorder = DeviceVideoRecorder()
    private let phoneRecorder = DeviceVideoRecorder()
    private let cameraOnlyRecorder = CameraOnlyRecorder()
    private var bubbleWindow: CameraBubbleWindow?
    private var phoneWindow: CameraBubbleWindow?
    private let clickTracker = ClickTracker()
    private let pointerTracker = PointerTracker()
    /// Decided when the take starts: the capture either has the system cursor
    /// in it or not, and the export must agree or there are 0 or 2 cursors.
    private var takeDrawsOwnCursor = false
    private let countdown = CountdownWindow()
    let teleprompter = TeleprompterWindow()

    private var projectFolder: URL?
    private var ticker: AnyCancellable?
    private var deviceObservers: [NSObjectProtocol] = []
    private var phoneWatch: AnyCancellable?

    init(workspace: Workspace, brand: BrandInfo) {
        self.workspace = workspace
        self.brand = brand
        lastShortURL = Self.latestShortTake(in: workspace)
        cameraOnlyRecorder.onOrientationChange = { [weak self] size in
            Task { @MainActor in self?.shortFrameSize = size }
        }
        refreshDestinationName()
        // One line per launch: after a reinstall this is the quickest way to
        // see which TCC grants survived (see "Reinstalling resets the permissions").
        Diagnostics.log("launch \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"): permissions screen=\(Permissions.screen) mic=\(Permissions.microphone) camera=\(Permissions.camera)")
        registerHotKeys()
        registerRemoteButton()
        // The handoff watch runs in every mode (for the auto-switch), started
        // once the app is up rather than inside init.
        DispatchQueue.main.async { [weak self] in self?.watchHandoffs() }
        watchDeviceChanges()
        watchFramingInputs()
    }

    deinit {
        let center = NotificationCenter.default
        for token in deviceObservers { center.removeObserver(token) }
    }

    // MARK: - Setup

    func refreshDestinationName() {
        existingFolders = workspace.existingLongFolders()
        // A destination the picker does not list (a handoff folder made a moment ago)
        // still has to be a valid selection, or the picker shows nothing chosen.
        if let folder = destinationFolder, !existingFolders.contains(folder),
           FileManager.default.fileExists(atPath: folder.path) {
            existingFolders.insert(folder, at: 0)
        }

        // A destination that got deleted or renamed underneath us falls back
        // to a new folder rather than failing at Record time.
        if let folder = destinationFolder,
           !FileManager.default.fileExists(atPath: folder.path) {
            destinationFolder = nil
            return
        }
        destinationName = displayPath(for: nextPlan().folder)
    }

    /// "takes/long/my-video/take-2", relative to the workspace.
    func displayPath(for url: URL) -> String {
        let base = workspace.root.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent
    }

    /// Where the next take will go, given the mode, the handoff and the picked folder.
    private func nextPlan() -> TakePlan {
        TakePlanner.plan(
            kind: captureMode == .short ? .short : .long,
            handoff: activeHandoff, videoFolder: destinationFolder,
            workspace: workspace, captureIsScreen: captureMode == .screen
        )
    }

    /// Makes the folder for this take. Remembers the plan and the handoff the take uses.
    private func resolveTakeFolder() throws -> URL {
        let plan = nextPlan()
        try FileManager.default.createDirectory(at: plan.folder, withIntermediateDirectories: true)
        takePlan = plan
        takeHandoff = activeHandoff
        takeStartedAt = Date()
        return plan.folder
    }

    /// The newest short.mov under `takes/shorts/`, for "Last take" after a relaunch.
    private static func latestShortTake(in workspace: Workspace) -> URL? {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: workspace.shortsRoot.path)) ?? []
        return names
            .map { workspace.shortsRoot.appendingPathComponent($0).appendingPathComponent("short.mov") }
            .filter { fm.fileExists(atPath: $0.path) }
            .max { a, b in
                let da = (try? fm.attributesOfItem(atPath: a.path)[.modificationDate] as? Date) ?? .distantPast
                let db = (try? fm.attributesOfItem(atPath: b.path)[.modificationDate] as? Date) ?? .distantPast
                return da < db
            }
    }

    func refreshPermissions() {
        hasScreenPermission = Permissions.screen.isUsable
        micPermission = Permissions.microphone
        cameraPermission = Permissions.camera
    }

    /// Asks for the microphone up front. Discovering it is missing halfway
    /// through a take is what produced unplayable files before.
    func grantMicrophone() async {
        await Permissions.requestMicrophone()
        refreshPermissions()
    }

    func grantCamera() async {
        await Permissions.requestCamera()
        refreshPermissions()
    }

    func checkPermissionAndLoadDisplays() async {
        refreshPermissions()
        guard hasScreenPermission else {
            displays = []
            return
        }
        do {
            let found = try await ScreenRecorder.availableDisplays()
            displays = found
            if selectedDisplayID == nil
                || !found.contains(where: { $0.displayID == selectedDisplayID }) {
                selectedDisplayID = found.first?.displayID
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
        refreshDevices()
    }

    /// Rescans cameras, microphones, and looks for a connected iPhone.
    func refreshDevices() {
        cameras = DeviceDiscovery.cameras()
        phones = DeviceDiscovery.phoneScreens()
        microphones = DeviceDiscovery.microphones()

        if selectedCameraID == nil || !cameras.contains(where: { $0.uniqueID == selectedCameraID }) {
            selectedCameraID = cameras.first?.uniqueID
        }
        if selectedPhoneID == nil || !phones.contains(where: { $0.uniqueID == selectedPhoneID }) {
            selectedPhoneID = phones.first?.uniqueID
        }

        // Only re-pinned when the current choice has actually disappeared
        // (unplugged), never just because something else showed up. Picking
        // a headset should be a decision you make, not something that
        // happens because it was the last device to connect.
        if selectedMicrophoneID == nil
            || !microphones.contains(where: { $0.uniqueID == selectedMicrophoneID }) {
            // Best available, not "built-in no matter what". With nothing plugged in
            // this still resolves to the Mac's own array; with a USB mic attached it
            // picks the USB mic, which is the whole point of owning one.
            selectedMicrophoneID = DeviceDiscovery.bestMicrophone()?.uniqueID
                ?? microphones.first?.uniqueID
        }
        if !phase.isActive, !phase.isBusy, !modeSettingsRestoredOnce, !microphones.isEmpty {
            modeSettingsRestoredOnce = true
            restoreModeSettings()
        }
        // The preferred mic is taken the moment it is (re)plugged in and on launch, never in the middle of a
        // take. A mic picked by hand in the Input list stays chosen until the preferred one is plugged in again.
        if let pm = preferredMicrophone {
            if !preferredMicWasPresent, !phase.isActive, !phase.isBusy, selectedMicrophoneID != pm.uniqueID {
                selectedMicrophoneID = pm.uniqueID
                Diagnostics.log("microphone: \(pm.localizedName) is plugged in, using it as the default")
            }
            preferredMicWasPresent = true
        } else {
            preferredMicWasPresent = false
        }
    }

    /// Cameras and iPhones come and go while the app is open. Without this
    /// the only way to notice was the Rescan button, which meant a device
    /// connected after Record was pressed never reached the take.
    private func watchDeviceChanges() {
        let center = NotificationCenter.default
        for name in [
            AVCaptureDevice.wasConnectedNotification,
            AVCaptureDevice.wasDisconnectedNotification
        ] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.refreshDevices()
                    self.reconcilePhone()
                    self.reconcileCamera()
                }
            }
            deviceObservers.append(token)
        }
    }

    /// Triggers the system permission prompt, then opens Settings if it was
    /// already denied (macOS only shows the prompt once per app).
    func requestScreenPermission() {
        if !CGRequestScreenCaptureAccess() {
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            )!
            NSWorkspace.shared.open(url)
        }
        Task { await checkPermissionAndLoadDisplays() }
    }

    func displayName(for display: SCDisplay) -> String {
        for screen in NSScreen.screens {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            if let number = screen.deviceDescription[key] as? NSNumber,
               number.uint32Value == display.displayID {
                return "\(screen.localizedName), \(display.width)×\(display.height)"
            }
        }
        return "Display \(display.displayID), \(display.width)×\(display.height)"
    }

    var selectedScreen: NSScreen? {
        guard let displayID = selectedDisplayID else { return NSScreen.main }
        for screen in NSScreen.screens {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            if let number = screen.deviceDescription[key] as? NSNumber,
               number.uint32Value == displayID {
                return screen
            }
        }
        return NSScreen.main
    }

    // MARK: - Camera bubble

    private func cameraEnabledChanged() {
        if cameraEnabled {
            Task { await enableCamera() }
        } else {
            cameraRecorder.detach()
            cameraRecorder.stopPreview()
            bubbleWindow?.orderOut(nil)
            // Same reasoning as the phone panel below: keep the window's
            // position through a take so footage already shot still lands.
            if !phase.isActive { bubbleWindow = nil }
        }
    }

    private func enableCamera() async {
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            cameraEnabled = false
            phase = .failed("Camera access was denied. Grant it in System Settings › Privacy & Security › Camera.")
            return
        }
        guard !cameras.isEmpty else {
            cameraEnabled = false
            phase = .failed("No camera found.")
            return
        }
        reconcileCamera()
    }

    private func showBubbleWindow() {
        guard bubbleWindow == nil, let screen = selectedScreen else { return }
        let framing = studioBubbleFraming
        let size = bubbleWindowSize(for: framing)
        let window = CameraBubbleWindow(
            previewLayer: cameraRecorder.previewLayer,
            size: size,
            cornerRadius: bubbleShape.cornerRadius(for: min(size.width, size.height))
        )
        window.setVideoGravity(.resizeAspectFill)
        window.setBubbleShape(bubbleShape, tiltDegrees: CGFloat(bubbleTilt))
        window.setStudioFraming(framing)
        if framing != nil {
            window.moveToStudioSlot(on: screen, face: faceLayout)
            window.flashFramingGuide()
        } else {
            window.moveToCorner(on: screen, leading: false)
        }
        window.orderFrontRegardless()
        bubbleWindow = window
        updateFramingRouting()
    }

    /// Newest camera frame, for the Studio layout preview. Thread-safe.
    var cameraFrameTap: CameraFrameTap { cameraRecorder.frameTap }

    /// Studio: the bubble is a live copy of the export's face card (shape,
    /// radius and crop. `FaceCardFraming`). Classic: nil, the bubble keeps
    /// its Circle/Rounded shape exactly as before.
    private var studioBubbleFraming: FaceCardFraming? {
        guard screenLayout == .studio else { return nil }
        let frame = cameraRecorder.frameSize
        let cameraSize = frame.width > 0 && frame.height > 0 ? frame : CGSize(width: 1920, height: 1080)
        return FaceCardFraming.reference(face: faceLayout, background: studioBackground, cameraSize: cameraSize)
    }

    /// Classic: a `bubbleSize` square. Studio: the card's on-screen aspect,
    /// locked, with the same area as that square, so the Size slider still
    /// works and the card never gets tiny or huge when switching looks.
    private func bubbleWindowSize(for framing: FaceCardFraming?) -> NSSize {
        let side = CGFloat(bubbleSize)
        guard let framing else { return NSSize(width: side, height: side) }
        let root = sqrt(max(framing.visibleAspect, 0.05))
        return NSSize(width: (side * root).rounded(), height: (side / root).rounded())
    }

    private func applyBubbleLayout(reanchor: Bool = false) {
        guard let window = bubbleWindow else { return }
        let framing = studioBubbleFraming
        let size = bubbleWindowSize(for: framing)
        // Shape first, so the resize lays out against the right framing.
        window.setStudioFraming(framing)
        window.apply(size: size, cornerRadius: bubbleShape.cornerRadius(for: min(size.width, size.height)))
        window.setBubbleShape(bubbleShape, tiltDegrees: CGFloat(bubbleTilt))
        if reanchor, let screen = selectedScreen {
            if framing != nil {
                window.moveToStudioSlot(on: screen, face: faceLayout)
                window.flashFramingGuide()
            } else {
                window.moveToCorner(on: screen, leading: false)
            }
        }
    }

    /// Studio takes record the camera's tallest format (portrait face card);
    /// pick it for the live preview too, so the bubble shows the same crop
    /// before Record as the file will have. Never mid-take.
    private func refreshCameraFormatForLayout() {
        guard !phase.isActive, cameraRecorder.isAttached else { return }
        let tall = (screenLayout == .studio)
        guard cameraRecorder.preferTallFormat != tall else { return }
        cameraRecorder.preferTallFormat = tall
        cameraRecorder.refreshFormat()
    }

    // MARK: - iPhone

    private func phoneEnabledChanged() {
        if phoneEnabled {
            refreshDevices()
            reconcilePhone()
        } else {
            phoneWaiting = false
            watchForPhone(false)
            phoneRecorder.detach()
            phoneRecorder.stopPreview()
            phoneWindow?.orderOut(nil)
            // Mid-take, the window object stays alive even though it is off
            // screen: its position is what the mixdown uses to place the
            // panel, so throwing it away here would silently discard every
            // second of phone footage already recorded. Switching the phone
            // off during a take means "stop filming it now", not "pretend it
            // was never there".
            if !phase.isActive { phoneWindow = nil }
        }
    }

    /// Matches what is plugged in against what is armed.
    ///
    /// Turning the iPhone on with nothing connected used to switch itself
    /// straight back off with an error, which meant the only supported order
    /// was plug in first, arm second, record third. Get that order wrong. /// connect the phone halfway through a take, say, and it silently never
    /// reached the video. Now arming just waits, and the phone joins whenever
    /// it turns up, take in progress or not.
    private func reconcilePhone() {
        guard phoneEnabled else { return }

        guard let device = phones.first(where: { $0.uniqueID == selectedPhoneID })
                ?? phones.first else {
            phoneWaiting = true
            phoneRecorder.detach()
            // The panel stays up through a mid-take unplug: its position on
            // screen is what the mixdown uses to place the panel, and losing
            // it here would drop the footage already recorded.
            if !phase.isActive {
                phoneWindow?.orderOut(nil)
                phoneWindow = nil
            }
            watchForPhone(true)
            return
        }

        phoneWaiting = false
        watchForPhone(false)
        guard !phoneRecorder.isAttached else { return }

        selectedPhoneID = device.uniqueID
        do {
            try phoneRecorder.configure(device: device, mirrored: false)
            // The phone reports 0x0 until it streams, so the panel's aspect
            // ratio has to be corrected once real frames arrive.
            phoneRecorder.onFrameSizeKnown = { [weak self] _ in
                Task { @MainActor in self?.applyPhoneLayout() }
            }
            phoneRecorder.startPreview()
            showPhoneWindow()
            Diagnostics.log("iPhone attached\(phase.isActive ? " mid-take" : "")")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func reconcileCamera() {
        guard cameraEnabled else { return }

        guard let device = cameras.first(where: { $0.uniqueID == selectedCameraID })
                ?? cameras.first else {
            cameraRecorder.detach()
            if !phase.isActive {
                bubbleWindow?.orderOut(nil)
                bubbleWindow = nil
            }
            return
        }
        guard !cameraRecorder.isAttached else { return }

        selectedCameraID = device.uniqueID
        do {
            // Same format choice as the take will make (see startRecording),
            // so the live bubble crops the frame the file will contain.
            cameraRecorder.preferTallFormat = (screenLayout == .studio)
            try cameraRecorder.configure(device: device, mirrored: mirrorCamera)
            // The first written frame is the truth; re-fit the card if it differs.
            cameraRecorder.onFrameSizeKnown = { [weak self] _ in
                Task { @MainActor in self?.applyBubbleLayout() }
            }
            cameraRecorder.startPreview()
            showBubbleWindow()
            Diagnostics.log("camera attached\(phase.isActive ? " mid-take" : "")")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// A connected iPhone is a CoreMediaIO DAL device rather than a plain
    /// USB camera, and it is not guaranteed to announce itself through the
    /// notifications above. While one is armed but absent, poll for it too. /// this only runs during that wait, so it costs nothing the rest of the
    /// time.
    private func watchForPhone(_ on: Bool) {
        guard on else {
            phoneWatch?.cancel()
            phoneWatch = nil
            return
        }
        guard phoneWatch == nil else { return }
        phoneWatch = Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, self.phoneEnabled, !self.phoneRecorder.isAttached else { return }
                let found = DeviceDiscovery.phoneScreens()
                guard !found.isEmpty else { return }
                self.phones = found
                self.reconcilePhone()
            }
    }

    private func showPhoneWindow() {
        guard phoneWindow == nil, let screen = selectedScreen else { return }
        let size = phonePanelSize()
        let window = CameraBubbleWindow(
            previewLayer: phoneRecorder.previewLayer,
            size: size,
            cornerRadius: 22
        )
        // Fit, not fill: cropping a phone screen would cut off the UI.
        window.setVideoGravity(.resizeAspect)
        window.setPhoneFrame(phoneShowsFrame)
        window.moveToCorner(on: screen, leading: true)
        window.orderFrontRegardless()
        phoneWindow = window
    }

    private func phonePanelSize() -> NSSize {
        let height = CGFloat(phoneHeight)
        let frame = phoneRecorder.frameSize
        let aspect = frame.height > 0 ? frame.width / frame.height : 9.0 / 19.5
        return NSSize(width: max(80, height * aspect), height: height)
    }

    private func applyPhoneLayout() {
        phoneWindow?.apply(size: phonePanelSize(), cornerRadius: 22)
    }

    // MARK: - Framing assistant

    /// "Check framing": the big live window. In Screen mode it turns the
    /// camera bubble on if it is off (that is the camera the take records);
    /// in Just me it starts a camera-only preview on the take's own session.
    func openFramingCheck() {
        if captureMode == .short {
            openShortPreview()
            return
        }
        Task { @MainActor in
            if captureMode == .cameraOnly {
                guard await Permissions.requestCamera() else {
                    refreshPermissions()
                    phase = .failed("Camera access is off. Tick Studio Recorder under System Settings › Privacy & Security › Camera.")
                    return
                }
                refreshPermissions()
            } else if !cameraEnabled {
                cameraEnabled = true
            }
            if framingWindow == nil {
                let window = FramingWindow(monitor: framing)
                window.onClose = { [weak self] in
                    Task { @MainActor in
                        self?.framingWindow = nil
                        self?.updateFramingRouting()
                    }
                }
                framingWindow = window
            }
            framingWindow?.makeKeyAndOrderFront(nil)
            updateFramingRouting()
        }
    }

    /// Every setting that changes a crop, the mode, the camera or the phase
    /// re-routes the assistant. One place, driven by the controller's own
    /// change stream, so no setting can be forgotten.
    private func watchFramingInputs() {
        objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateFramingRouting() }
            .store(in: &framingSinks)
        framing.$report
            .receive(on: DispatchQueue.main)
            .sink { [weak self] report in self?.showFramingOnBubble(report) }
            .store(in: &framingSinks)
    }

    /// Every crop you can appear in with the current settings: the Just me
    /// frame or shape, the Classic bubble, or the Studio card, all four
    /// Dynamic states (Face / Side / Card / Corner) when Dynamic applies.
    private func framingSpecs() -> [FramingCropSpec] {
        switch captureMode {
        case .cameraOnly:
            return [.fullFrame]
        case .short:
            // Short has its own window; the assistant is idle in this mode.
            return [.fullFrame]
        case .screen:
            guard screenLayout == .studio else { return [.shape(bubbleShape)] }
            let dynamic = LayoutTimeline.applies(
                mode: layoutMode, layout: screenLayout, background: studioBackground, hasCamera: true
            )
            return FramingCropSpec.studioCrops(face: faceLayout, background: studioBackground, dynamic: dynamic)
        }
    }

    private func updateFramingRouting() {
        let windowOpen = framingWindow != nil
        let cameraOnly = captureMode == .cameraOnly
        let short = captureMode == .short
        let shortOpen = short && shortWindow != nil

        if (cameraOnly && windowOpen) || shortOpen {
            ensureCameraOnlyPreview()
        } else if cameraOnlyPreviewCameraID != nil, !phase.isActive, !phase.isBusy {
            cameraOnlyRecorder.stopPreview()
            cameraOnlyPreviewCameraID = nil
        }
        if short {
            let size = cameraOnlyRecorder.frameSize
            if size.width >= 2, size != shortFrameSize { shortFrameSize = size }
        }

        let tap: CameraFrameTap?
        if cameraOnly {
            tap = windowOpen ? cameraOnlyRecorder.frameTap : nil
        } else if short {
            tap = nil
        } else {
            tap = cameraEnabled && cameraRecorder.isAttached ? cameraRecorder.frameTap : nil
        }
        let bubbleShowing = captureMode == .screen && bubbleWindow?.isVisible == true
        let wanted = tap != nil && (windowOpen || (bubbleShowing && framingHintsOnBubble))
        framing.update(specs: framingSpecs(), mirrored: mirrorCamera, source: wanted ? tap : nil, slow: phase.isActive)

        // Short's own guide: fed by the same camera-only
        // session's tap whenever its window is open, which, unlike the
        // Just me / Screen assistant, is effectively "whenever Short mode is
        // active" (openShortPreview() opens it by itself). Runs through a
        // take too, at the slower cadence, purely to keep measuring. // nothing here can affect what gets recorded (see CameraOnlyRecorder
        // .frameTap and ShortExport, which read the writer's own samples).
        shortFraming.update(
            specs: shortOpen ? [.short] : [], mirrored: mirrorCamera,
            source: shortOpen ? cameraOnlyRecorder.frameTap : nil, slow: phase.isActive
        )

        var live: AVCaptureVideoPreviewLayer?
        if windowOpen {
            if cameraOnly {
                live = cameraOnlyRecorder.previewLayer
            } else if short {
                live = nil   // the Short window hosts the layer
            } else if cameraEnabled {
                if framingCameraPreview == nil { framingCameraPreview = cameraRecorder.makePreviewLayer() }
                live = framingCameraPreview
            }
        }
        if framing.livePreview !== live { framing.livePreview = live }
        showFramingOnBubble(framing.report)
    }

    /// Just me + window open, between takes: a camera-only preview on the
    /// take's own session (re-set if the camera choice changes).
    private func ensureCameraOnlyPreview() {
        guard !phase.isActive, !phase.isBusy else { return }
        guard let camera = cameras.first(where: { $0.uniqueID == selectedCameraID }) ?? cameras.first else { return }
        let short = captureMode == .short
        guard cameraOnlyPreviewCameraID != camera.uniqueID || cameraOnlyPreviewShort != short else { return }
        startCameraOnlyPreview(camera)
    }

    private func startCameraOnlyPreview(_ camera: AVCaptureDevice) {
        cameraOnlyPreviewCameraID = camera.uniqueID
        let short = captureMode == .short
        cameraOnlyPreviewShort = short
        setShortProfile(short)
        do {
            try cameraOnlyRecorder.configurePreview(camera: camera, mirrored: mirrorCamera)
            cameraOnlyRecorder.startPreview()
            if short {
                shortFrameSize = cameraOnlyRecorder.frameSize
                applyShortViewerDisplay()
            }
            Diagnostics.log("framing preview (\(short ? "short" : "just me")) on \(camera.localizedName)")
        } catch {
            Diagnostics.log(error: error, context: "framing preview")
        }
    }

    /// After a Just me take ends (or fails, or is discarded): back to the
    /// camera-only preview if the framing window is open, otherwise off.
    private func settleCameraOnlyPreview() {
        cameraOnlyPreviewCameraID = nil
        let wanted = (framingWindow != nil && captureMode == .cameraOnly)
            || (shortWindow != nil && captureMode == .short)
        if wanted,
           let camera = cameras.first(where: { $0.uniqueID == selectedCameraID }) ?? cameras.first {
            startCameraOnlyPreview(camera)
        } else {
            cameraOnlyRecorder.stopPreview()
        }
    }

    /// The compact version: traffic light + one short hint on the bubble.
    private func showFramingOnBubble(_ report: FramingReport) {
        guard let bubble = bubbleWindow else { return }
        guard framingHintsOnBubble, captureMode == .screen, framing.isRunning else {
            bubble.setFramingStatus(nil, hint: "")
            return
        }
        let first = report.overall.hints.first ?? ""
        // The bubble is small: the action only, no "(Side, Corner)" and no
        // reason after the comma.
        let short = first.components(separatedBy: " (").first?
            .components(separatedBy: ", ").first ?? first
        bubble.setFramingStatus(report.overall.status, hint: short)
    }

    // MARK: - Teleprompter

    /// Opens the prompter if it is closed (used by the Studio app handoff).
    func openTeleprompter() {
        guard !teleprompter.isVisible, let screen = selectedScreen ?? NSScreen.main else { return }
        teleprompter.show(on: screen)
        teleprompterVisible = teleprompter.isVisible
    }

    func toggleTeleprompter() {
        guard let screen = selectedScreen else { return }
        teleprompter.toggle(on: screen)
        teleprompterVisible = teleprompter.isVisible
    }

    // MARK: - Hot keys

    private func registerHotKeys() {
        HotKeyCenter.shared.register(.toggleRecording) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                if self.phase.isActive {
                    await self.stop()
                } else if !self.phase.isBusy {
                    await self.start()
                }
            }
        }
        HotKeyCenter.shared.register(.togglePause) { [weak self] in
            Task { @MainActor in self?.togglePause() }
        }
        HotKeyCenter.shared.register(.zoomHere) { [weak self] in
            Task { @MainActor in self?.markZoom(zoomIn: true) }
        }
        HotKeyCenter.shared.register(.zoomOut) { [weak self] in
            Task { @MainActor in self?.markZoom(zoomIn: false) }
        }
        HotKeyCenter.shared.register(.prompterBack) { [weak self] in
            Task { @MainActor in self?.teleprompter.model.stepBox(-1) }
        }
        HotKeyCenter.shared.register(.prompterNext) { [weak self] in
            Task { @MainActor in self?.teleprompter.model.stepBox(1) }
        }
    }

    // MARK: - Bluetooth button

    private func registerRemoteButton() {
        let remote = RemoteButton.shared
        remote.onPress = { [weak self] in
            Task { @MainActor in await self?.remoteToggle() }
        }
        remote.onLongPress = { [weak self] in
            Task { @MainActor in self?.remoteLongPress() }
        }
        remote.onStatusChange = { [weak self] status in
            Task { @MainActor in self?.remoteStatus = status }
        }
        remote.arm()
        remoteStatus = remote.status
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            // Let Bluetooth come back first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { RemoteButton.shared.rearmAfterWake() }
        }
    }

    /// While recording: one press stops, two quick presses discard the take
    /// (the trash button, without the confirmation, since you are across the
    /// room). Idle: one press starts. Presses during the countdown, while
    /// preparing or while a take is being finished are ignored.
    ///
    /// A stop has to wait `TailTrim.doublePressWindow` to see whether a second
    /// press is coming; the recording runs on during that wait, so the tail
    /// trim adds the window back (`TailTrim.remoteTotalSeconds`).
    func remoteToggle() async {
        if phase.isActive {
            if let pending = pendingRemoteStop {
                pending.cancel()
                pendingRemoteStop = nil
                Diagnostics.log("remote button: double press -> discard")
                await discard()
                NSSound(named: "Basso")?.play()
                return
            }
            pendingRemoteStop = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(TailTrim.doublePressWindow * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.pendingRemoteStop = nil
                guard self.phase.isActive else { return }
                self.stopCameFromRemote = true
                await self.stop()
                NSSound(named: "Pop")?.play()
            }
        } else if !phase.isBusy {
            await start()
        } else {
            // Countdown / preparing / finishing a take. Silent drops read as "the button is broken".
            Diagnostics.log("remote button: press ignored, studio busy (\(phase))")
            NSSound(named: "Funk")?.play()
        }
    }

    /// Hold the clicker (>= 0.6 s) while recording = next teleprompter box. The press that began
    /// the hold already queued a stop; that is cancelled here, inside the double-press window
    /// (0.7 s), so a hold never ends the take. Idle: ignored (the press may have started a take).
    func remoteLongPress() {
        guard phase.isActive, teleprompter.isVisible else { return }
        pendingRemoteStop?.cancel()
        pendingRemoteStop = nil
        teleprompter.model.stepBox(1)
        NSSound(named: "Tink")?.play()
        Diagnostics.log("remote button: long press -> next teleprompter box")
    }

    func learnRemoteButton() { RemoteButton.shared.startLearning() }
    func cancelLearnRemoteButton() { RemoteButton.shared.cancelLearning() }
    func forgetRemoteButton() { RemoteButton.shared.forget() }
    func rearmRemoteButton() { RemoteButton.shared.arm() }

    /// Reads and clears the flag, so a later ⌘R stop is never trimmed.
    private func takeRemoteStopFlag() -> Bool {
        defer { stopCameFromRemote = false }
        return stopCameFromRemote
    }

    /// A manual zoom mark on the pointer. Only while recording a screen take;
    /// manual marks always win over the automatic policy at export.
    func markZoom(zoomIn: Bool) {
        guard phase == .recording, captureMode == .screen else { return }
        pointerTracker.addMark(zoomIn: zoomIn)
        zoomMarkCount = pointerTracker.markCount
        Diagnostics.log("zoom mark \(zoomIn ? "in" : "out") (\(zoomMarkCount) this take)")
    }

    // MARK: - Camera-only recording

    /// A talking-head take: camera + mic, no screen. Needs no Screen
    /// Recording permission at all, which is why it doesn't reuse the
    /// screen path.
    private func startCameraOnly() async {
        lastFinalURL = nil

        guard !(await Permissions.requestCamera() == false) else {
            refreshPermissions()
            phase = .failed(
                "Camera access is off. Tick Studio Recorder under System Settings › "
                + "Privacy & Security › Camera, then reopen the app."
            )
            Diagnostics.log("camera-only start aborted: camera permission denied")
            return
        }
        guard await Permissions.requestMicrophone() else {
            refreshPermissions()
            phase = .failed(
                "Microphone access is off, so the take would have no voice. Tick "
                + "Studio Recorder under System Settings › Privacy & Security › "
                + "Microphone, then reopen the app."
            )
            Diagnostics.log("camera-only start aborted: microphone permission denied")
            return
        }
        refreshPermissions()

        guard let camera = cameras.first(where: { $0.uniqueID == selectedCameraID })
                ?? cameras.first else {
            phase = .failed("No camera found.")
            return
        }
        refreshDevices()
        guard let microphone = microphones.first(where: { $0.uniqueID == selectedMicrophoneID })
                ?? microphones.first else {
            phase = .failed("No microphone found.")
            return
        }
        Diagnostics.log("camera-only mic: \(microphone.localizedName)")

        if countdownSeconds > 0, let screen = selectedScreen {
            phase = .countingDown
            await countdown.run(on: screen, from: countdownSeconds)
        }

        phase = .preparing

        let isShort = captureMode == .short
        do {
            let folder = try resolveTakeFolder()
            projectFolder = folder
            Diagnostics.log("\(isShort ? "short" : "camera-only") start -> \(displayPath(for: folder))")

            let clock = RecordingClock()
            self.clock = clock

            cameraOnlyRecorder.onFailure = { [weak self] error in
                Task { @MainActor in
                    // Impossible to miss: Record goes back to idle, red message, sound.
                    self?.phase = .failed("RECORDING FAILED. Nothing was saved. Press Record again. (\(error.localizedDescription))")
                    self?.stopTicker()
                    self?.discardEmptyProjectFolder()
                    NSSound(named: "Basso")?.play()
                    NSSound.beep()
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            // The take owns the session now (camera + mic); the framing
            // window's preview-only setup is replaced, and restored after.
            cameraOnlyPreviewCameraID = nil
            let previewSize = isShort ? cameraOnlyRecorder.deliveredFrameSize : nil
            setShortProfile(isShort)
            try cameraOnlyRecorder.configure(
                camera: camera, microphone: microphone, mirrored: mirrorCamera
            )
            cameraOnlyRecorder.startPreview()

            if isShort {
                // The crop is frozen now; dragging is locked until the take ends.
                // The frame was placed on the (maybe mirrored) preview; the
                // crop is cut from the file, which may not be mirrored.
                let previewMirrored = cameraOnlyRecorder.previewMirrored
                let fileMirrored = cameraOnlyRecorder.fileMirrored
                shortTakeSettings = ShortTake.Settings(
                    filePosition: ShortTake.filePosition(previewPosition: shortPosition, previewMirrored: previewMirrored, fileMirrored: fileMirrored),
                    previewPosition: shortPosition,
                    fileMirrored: fileMirrored, previewMirrored: previewMirrored,
                    rotation: cameraOnlyRecorder.rotationAngle, camera: camera.localizedName
                )
                shortFrameSize = cameraOnlyRecorder.frameSize
                applyShortViewerDisplay()
                let size = cameraOnlyRecorder.frameSize
                Diagnostics.log("short take: feed \(Int(size.width))x\(Int(size.height)), rotation \(Int(cameraOnlyRecorder.rotationAngle))°, position x \(String(format: "%.3f", shortPosition.x)) y \(String(format: "%.3f", shortPosition.y)), file mirrored \(fileMirrored), preview mirrored \(previewMirrored)"
                    + (previewSize.map { $0 != size ? " (preview delivered \(Int($0.width))x\(Int($0.height)))" : "" } ?? ""))
            }

            // The whole camera frame goes straight into take.mov. A Short is cut
            // from it afterwards, so take.mov stays the untouched source.
            try cameraOnlyRecorder.startRecording(
                to: folder.appendingPathComponent("take.mov"), clock: clock
            )

            phase = .recording
            startTicker()
        } catch {
            Diagnostics.log(error: error, context: "camera-only start")
            phase = .failed(error.localizedDescription)
            discardEmptyProjectFolder()
        }
    }

    private func stopCameraOnly(byRemote: Bool = false) async {
        stopTicker()
        phase = .finishing

        guard let folder = projectFolder, let plan = takePlan else { return }

        do {
            guard let recordedURL = await cameraOnlyRecorder.stopRecording() else {
                throw CameraOnlyRecorder.RecorderError.writerFailed("nothing was captured")
            }
            settleCameraOnlyPreview()

            var crop: TakeManifest.Crop?
            var preview: String?
            if captureMode == .short {
                let (result, mirrored) = try await finishShort(folder: folder, rawURL: recordedURL, byRemote: byRemote)
                crop = TakeManifest.Crop(
                    x: Int(result.crop.minX), y: Int(result.crop.minY),
                    w: Int(result.crop.width), h: Int(result.crop.height), mirrored: mirrored
                )
                preview = "short.mov"
            } else if byRemote {
                await TailTrim.trim(recordedURL, seconds: TailTrim.remoteTotalSeconds)
            }

            await saveTake(
                plan: plan, folder: folder, camera: recordedURL, screen: nil,
                micSource: recordedURL, hasClicks: false, crop: crop, preview: preview,
                stoppedBy: byRemote ? "remote-button" : nil
            )
            let finalURL = recordedURL
            lastFinalURL = finalURL
            phase = .finished(finalURL)
            Diagnostics.log("camera-only finished \(displayPath(for: folder))")
            // A long take makes its video folder the sticky destination, so the next
            // take lands alongside it. Shorts are one take per folder and never do.
            if captureMode != .short, destinationFolder == nil {
                destinationFolder = folder.deletingLastPathComponent()
            }
            projectFolder = nil
            refreshDestinationName()
        } catch {
            Diagnostics.log(error: error, context: "camera-only stop")
            phase = .failed(error.localizedDescription)
            settleCameraOnlyPreview()
            discardEmptyProjectFolder()
        }
    }

    /// Writes `take.json` straight away, then the separate `mic.wav` in the background
    /// (the manifest is updated when the file exists).
    private func saveTake(
        plan: TakePlan, folder: URL, camera: URL?, screen: URL?, micSource: URL?,
        hasClicks: Bool, crop: TakeManifest.Crop?, preview: String?, stoppedBy: String?
    ) async {
        let info = await MicExport.probe(camera ?? screen ?? folder)
        let manifest = TakeManifest(
            plan: plan, started: takeStartedAt, durationSeconds: info.duration, fps: info.fps,
            camera: camera == nil ? nil : "take.mov", screen: screen == nil ? nil : "screen.mov",
            mic: nil, clicks: hasClicks ? "clicks.json" : nil, crop: crop,
            composite: nil, preview: preview, stoppedBy: stoppedBy
        )
        do {
            try manifest.write(to: folder)
        } catch {
            Diagnostics.log(error: error, context: "write take.json")
        }
        guard let micSource else { return }
        Task.detached(priority: .utility) {
            do {
                try await MicExport.writeWav(from: micSource, to: folder.appendingPathComponent("mic.wav"))
                TakeManifest.setFile("mic", "mic.wav", in: folder)
            } catch {
                Diagnostics.log(error: error, context: "mic.wav")
            }
        }
    }

    // MARK: - Short mode

    /// take.mov → short.mov (1080x1920, 30 fps, mic audio), cut with the
    /// position frozen when Record was pressed. take.mov itself is left untouched.
    private func finishShort(folder: URL, rawURL: URL, byRemote: Bool = false) async throws -> (ShortTake.Result, Bool) {
        var settings = shortTakeSettings ?? ShortTake.Settings(
            filePosition: shortPosition, previewPosition: shortPosition,
            fileMirrored: cameraOnlyRecorder.fileMirrored, previewMirrored: cameraOnlyRecorder.previewMirrored,
            rotation: cameraOnlyRecorder.rotationAngle
        )
        settings.tailTrim = byRemote ? TailTrim.remoteTotalSeconds : 0
        shortTakeSettings = nil
        let result = try await ShortTake.finish(folder: folder, rawURL: rawURL, settings: settings)
        lastShortURL = result.shortURL
        let crop = result.crop
        Diagnostics.log("short finished \(displayPath(for: folder)): crop \(Int(crop.minX)),\(Int(crop.minY)) \(Int(crop.width))x\(Int(crop.height)) of \(Int(result.feed.width))x\(Int(result.feed.height)), \(String(format: "%.1f", result.duration))s")
        return (result, settings.fileMirrored)
    }

    /// Short and Just me share one session: Short records the tallest format
    /// and (by default) an unmirrored file; Just me neither.
    private func setShortProfile(_ short: Bool) {
        cameraOnlyRecorder.shortProfile = short
        cameraOnlyRecorder.maxHeight = cameraQuality.maxHeight
        cameraOnlyRecorder.fileMirrorOverride = short ? shortMirrorFile : nil
    }

    /// "Mirror the recorded file" changed: apply it now, between takes only.
    private func applyShortMirroring() {
        guard captureMode == .short, !phase.isActive, !phase.isBusy else { return }
        cameraOnlyRecorder.fileMirrorOverride = shortMirrorFile
        cameraOnlyRecorder.setMirrored(mirrorCamera)
        applyShortViewerDisplay()
    }

    /// Viewer view shows exactly the file: if the preview is a mirror and the
    /// file is not (or the other way round), the preview is shown in the
    /// file's orientation while Viewer view is on.
    func setShortViewerView(_ on: Bool) {
        shortViewerView = on
        applyShortViewerDisplay()
    }

    private func applyShortViewerDisplay() {
        guard captureMode == .short else { return }
        let showFile = shortViewerView && mirrorCamera != cameraOnlyRecorder.fileMirrored
        cameraOnlyRecorder.setPreviewDisplayMirrored(showFile ? cameraOnlyRecorder.fileMirrored : mirrorCamera)
    }

    // MARK: - Handoff from the Studio app

    /// Reads both handoff files (every 2 s, in every mode). A new, fresh request
    /// sets the mode, the video folder and the teleprompter once, and never
    /// during a take. If both files are new, the newer one acts.
    func refreshHandoffs() {
        if let current = handoff, Date().timeIntervalSince(current.createdAt) >= Handoff.maxAge {
            handoff = nil
        }
        guard !(phase.isActive || phase.isBusy) else { return }
        let candidates = [Handoff.load(from: workspace.nextTakeURL), Handoff.load(from: workspace.nextRecordingURL)]
        guard let new = HandoffArbiter.pick(candidates, used: ledger.used) else { return }
        ledger.markUsed(new)
        apply(new)
    }

    private func apply(_ new: Handoff) {
        Diagnostics.log("handoff: \(new.kind.rawValue) \(new.id) (\(new.created)), mode \(new.mode.rawValue)")
        handoff = new
        switch new.kind {
        case .short:
            if captureMode != .short { captureMode = .short }
        case .long:
            let wanted: CaptureMode = new.mode == .screen ? .screen : .cameraOnly
            if captureMode != wanted { captureMode = wanted }
            if let out = new.outDir, workspace.isInsideTakes(out) {
                let folder = TakePlanner.videoFolder(of: out)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let known = workspace.existingLongFolders().first {
                        $0.standardizedFileURL.path == folder.standardizedFileURL.path
                    }
                    destinationFolder = known ?? folder
                } catch {
                    Diagnostics.log(error: error, context: "handoff: create \(folder.path)")
                }
            }
        }
        loadPrompter(for: new)
        refreshDestinationName()
    }

    /// Puts the request's script or talking points in the teleprompter. With nothing to
    /// read it clears what the last request left there (unless the text was edited).
    private func loadPrompter(for request: Handoff) {
        let text = request.prompterText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            clearLoadedPrompter()
            if teleprompter.isVisible {
                teleprompter.hide()
                teleprompterVisible = false
            }
            return
        }
        teleprompter.model.style = request.prompterStyle
        teleprompter.model.text = text
        teleprompter.model.restart()
        handoffLoadedText = text
        if request.mode != .cards { teleprompter.model.mode = .follow }
        openTeleprompter()
        teleprompter.syncSpeech()
    }

    private func clearLoadedPrompter() {
        if let loaded = handoffLoadedText, teleprompter.model.text == loaded {
            teleprompter.model.text = ""
            teleprompter.model.style = .script
        }
        handoffLoadedText = nil
    }

    /// "Not this one": forget the request, point Save to back at a new folder and
    /// clear the script it loaded. A new press in the Studio app is used again.
    func ignoreHandoff() {
        guard let current = handoff else { return }
        Diagnostics.log("handoff: ignoring \(current.id) (\(current.created))")
        if current.kind == .long, let out = current.outDir, let folder = destinationFolder,
           folder.standardizedFileURL.path == TakePlanner.videoFolder(of: out).standardizedFileURL.path {
            destinationFolder = nil
        }
        handoff = nil
        clearLoadedPrompter()
        refreshDestinationName()
    }

    private func watchHandoffs() {
        refreshHandoffs()
        guard handoffWatch == nil else { return }
        handoffWatch = Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshHandoffs() }
    }

    /// The live 9:16 preview. Opens by itself when Short is picked.
    func openShortPreview() {
        Task { @MainActor in
            guard await Permissions.requestCamera() else {
                refreshPermissions()
                phase = .failed("Camera access is off. Tick Studio Recorder under System Settings › Privacy & Security › Camera.")
                return
            }
            refreshPermissions()
            guard captureMode == .short else { return }
            if shortWindow == nil {
                let window = ShortPreviewWindow(controller: self)
                window.onClose = { [weak self] in
                    Task { @MainActor in
                        guard let self else { return }
                        self.shortWindow = nil
                        self.setShortViewerView(false)
                        self.objectWillChange.send()
                        self.updateFramingRouting()
                    }
                }
                shortWindow = window
                objectWillChange.send()
            }
            shortWindow?.makeKeyAndOrderFront(nil)
            updateFramingRouting()
        }
    }

    func closeShortPreview() {
        shortWindow?.close()
    }

    func centreShortCrop() {
        guard !shortCropLocked else { return }
        shortPosition = .centred
    }

    /// Plays the newest short.mov straight away.
    func replayLastShort() {
        guard let url = lastShortURL, FileManager.default.fileExists(atPath: url.path) else { return }
        if shortReplayWindow == nil { shortReplayWindow = ShortReplayWindow() }
        shortReplayWindow?.play(url)
    }

    private func captureModeChanged(from old: CaptureMode) {
        if !phase.isActive, !phase.isBusy { restoreModeSettings() }
        if captureMode == .short {
            setShortProfile(true)
            openShortPreview()
        } else if old == .short {
            shortWindow?.close()
            shortReplayWindow?.close()
            setShortProfile(false)
        }
        updateFramingRouting()
    }

    // MARK: - Recording

    func start() async {
        guard !phase.isActive, !phase.isBusy else { return }

        if captureMode.usesCameraOnlyRecorder {
            await startCameraOnly()
            return
        }

        guard let displayID = selectedDisplayID,
              let display = displays.first(where: { $0.displayID == displayID }),
              let screen = selectedScreen else {
            phase = .failed("Pick a display first.")
            return
        }

        lastFinalURL = nil

        // Check every permission BEFORE the countdown, so a missing grant is
        // caught while nothing is at stake rather than after a take.
        if captureMicrophone, !(await Permissions.requestMicrophone()) {
            refreshPermissions()
            phase = .failed(
                "Microphone access is off, so the take would have no voice. "
                + "Tick Studio Recorder under System Settings › Privacy & Security › "
                + "Microphone, then reopen the app. Or switch Microphone off to "
                + "record without it."
            )
            Diagnostics.log("start aborted: microphone permission denied")
            return
        }
        if cameraEnabled, !(await Permissions.requestCamera()) {
            refreshPermissions()
            phase = .failed(
                "Camera access is off. Tick Studio Recorder under System Settings › "
                + "Privacy & Security › Camera, then reopen the app. Or switch the "
                + "camera bubble off."
            )
            Diagnostics.log("start aborted: camera permission denied")
            return
        }
        refreshPermissions()

        if countdownSeconds > 0 {
            phase = .countingDown
            await countdown.run(on: screen, from: countdownSeconds)
        }

        phase = .preparing

        do {
            let folder = try resolveTakeFolder()
            projectFolder = folder
            Diagnostics.log("start -> \(displayPath(for: folder))")

            let clock = RecordingClock()
            self.clock = clock

            let recorder = ScreenRecorder(clock: clock)
            recorder.onFailure = { [weak self] error in
                Task { @MainActor in
                    self?.phase = .failed(error.localizedDescription)
                    self?.stopTicker()
                    self?.pointerTracker.stop()
                }
            }
            screenRecorder = recorder

            let options = ScreenRecorder.Options(
                display: display,
                captureMicrophone: captureMicrophone,
                captureSystemAudio: captureSystemAudio,
                microphoneDeviceID: selectedMicrophoneID,
                targetHeight: quality.targetHeight,
                // Leave the cursor out of the pixels only; you still see your
                // normal cursor, and nothing changes when not recording.
                showsCursor: !ownCursor
            )
            takeDrawsOwnCursor = ownCursor

            try await recorder.start(
                options: options,
                rawURL: folder.appendingPathComponent("screen.mov")
            )

            if cameraEnabled {
                // Studio screen takes use the tall camera format for the portrait face card.
                cameraRecorder.preferTallFormat = (screenLayout == .studio)
                cameraRecorder.refreshFormat()
                applyBubbleLayout()
                try? cameraRecorder.startRecording(
                    to: folder.appendingPathComponent("take.mov"), clock: clock
                )
            }
            if phoneEnabled {
                try? phoneRecorder.startRecording(
                    to: folder.appendingPathComponent("iphone.mov"), clock: clock
                )
            }

            // The part of the screen that ends up in screen.mov, in global
            // points: clicks and the pointer are logged relative to it.
            let crop = ScreenRecorder.sourceRect(for: display)
            let captureRect = CGRect(
                x: screen.frame.minX + crop.minX,
                y: screen.frame.minY + (screen.frame.height - crop.maxY),
                width: crop.width,
                height: crop.height
            )

            clickTracker.reset()
            zoomMarkCount = 0
            if zoomMode != .off || clickHighlight || ownCursor {
                clickTracker.start(clock: clock, screen: screen, captureRect: captureRect)
            }
            pointerTracker.reset()
            pointerTracker.start(clock: clock, captureRect: captureRect)

            phase = .recording
            startTicker()
        } catch {
            Diagnostics.log(error: error, context: "start")
            phase = .failed(error.localizedDescription)
            screenRecorder = nil
            discardEmptyProjectFolder()
        }
    }

    /// A take that never started should not leave an empty folder behind.
    /// The folder is always this take's own, never one that holds earlier takes.
    private func discardEmptyProjectFolder() {
        guard let folder = projectFolder else { return }

        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        let realFiles = contents.filter { name in
            guard name != ".DS_Store" else { return false }
            let url = folder.appendingPathComponent(name)
            let attributes = try? fm.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            return size > 0
        }
        if realFiles.isEmpty {
            try? fm.removeItem(at: folder)
            Diagnostics.log("discarded empty folder \(folder.lastPathComponent)")
        }
        projectFolder = nil
        refreshDestinationName()
    }

    func togglePause() {
        // Both modes retime through the same clock, so pause works
        // identically whether or not there's a screen recorder.
        guard screenRecorder != nil || captureMode.usesCameraOnlyRecorder else { return }
        switch phase {
        case .recording:
            clock.pause()
            phase = .paused
        case .paused:
            clock.resume()
            phase = .recording
        default:
            break
        }
    }

    func stop() async {
        guard phase.isActive else { return }
        let stoppedByRemote = takeRemoteStopFlag()

        if captureMode.usesCameraOnlyRecorder {
            await stopCameraOnly(byRemote: stoppedByRemote)
            return
        }

        guard let recorder = screenRecorder, let folder = projectFolder, let plan = takePlan else { return }
        stopTicker()
        clickTracker.stop()
        pointerTracker.stop()
        phase = .finishing

        // Positions are read now, so the overlays land where they were left.
        let renderSize = recorder.pixelSize
        let screen = selectedScreen
        var bubbleRect = CGRect.zero
        var phoneRect = CGRect.zero
        var bubbleRadius: CGFloat = 0
        var phoneRadius: CGFloat = 0

        // Gated on the window rather than on the toggle: switching an overlay
        // off partway through a take must not throw away what it already
        // filmed. Whether anything is drawn is decided further down by
        // whether a file and any segments actually exist.
        if let screen, let bubbleWindow {
            bubbleRect = bubbleWindow.rectInRenderSpace(screen: screen, renderSize: renderSize)
            let scale = screen.frame.height > 0 ? renderSize.height / screen.frame.height : 1
            bubbleRadius = bubbleShape.cornerRadius(for: CGFloat(bubbleSize)) * scale
        }
        if let screen, let phoneWindow {
            phoneRect = phoneWindow.rectInRenderSpace(screen: screen, renderSize: renderSize)
            let scale = screen.frame.height > 0 ? renderSize.height / screen.frame.height : 1
            phoneRadius = 22 * scale
        }

        do {
            let rawURL = try await recorder.stop()
            let cameraURL = await cameraRecorder.stopRecording()
            let phoneURL = await phoneRecorder.stopRecording()
            let cameraSegments = cameraRecorder.recordedSegments()
            let phoneSegments = phoneRecorder.recordedSegments()

            let clicks = clickTracker.clicks
            if !clicks.isEmpty {
                clickTracker.save(to: folder.appendingPathComponent("clicks.json"))
            }
            let pointerLog = pointerTracker.log(systemCursorInCapture: !takeDrawsOwnCursor)
            pointerTracker.save(pointerLog, to: folder.appendingPathComponent("cursor.json"))

            var request = Mixdown.Request(rawURL: rawURL)
            request.cameraURL = cameraURL
            request.phoneURL = phoneURL
            request.cameraSegments = cameraSegments
            request.phoneSegments = phoneSegments
            request.bubbleRect = bubbleRect
            request.bubbleCornerRadius = bubbleRadius
            request.bubbleShape = bubbleShape
            request.bubbleTilt = CGFloat(bubbleTilt)

            request.phoneRect = phoneRect
            request.phoneCornerRadius = phoneRadius
            request.phoneShowsFrame = phoneShowsFrame
            request.clicks = clicks
            request.showClickHighlight = clickHighlight

            let loggedPath = PointerPath(samples: pointerLog.samples)
            request.zoom = ZoomTimeline.build(
                mode: zoomMode,
                activity: ZoomActivity(
                    clicks: clicks, keys: pointerLog.keys ?? [],
                    pointer: loggedPath, marks: pointerLog.marks
                ),
                maxScale: CGFloat(zoomAmount)
            )

            request.layout = screenLayout
            request.faceLayout = faceLayout
            request.cameraGrade = cameraGrade
            request.background = studioBackground
            if frameFocusedWindow, let rows = pointerLog.windows {
                let focus = FocusPath(windows: rows)
                request.focus = focus.isTrivial ? nil : focus
            }
            if export4K, screenLayout == .studio, renderSize.width >= 2560 {
                request.outputSize = CGSize(width: 3840, height: 2160)
            }
            if takeDrawsOwnCursor {
                // Path from the pointer log; if that somehow came back empty,
                // glide between the clicks rather than show no cursor at all.
                request.pointer = loggedPath ?? PointerPath.fromClicks(clicks)
                request.pointer?.shapeKeys = pointerLog.shapeKeys
            }
            // Why each zoom fired, for the edit and for tuning the policy.
            Self.saveZoomSidecar(
                request.zoom, mode: zoomMode,
                to: folder.appendingPathComponent("zoom.json")
            )

            // Dynamic layout: decided from the take's own frames, mic and logs.
            if LayoutTimeline.applies(
                mode: layoutMode, layout: screenLayout, background: studioBackground, hasCamera: cameraURL != nil
            ) {
                let signals = await LayoutSignals.load(rawURL: rawURL)
                let duration = (try? await AVURLAsset(url: rawURL).load(.duration).seconds) ?? 0
                request.layoutTimeline = LayoutTimeline.build(
                    duration: duration, clicks: clicks, keys: pointerLog.keys ?? [],
                    pointer: loggedPath,
                    zoom: request.zoom, signals: signals, cameraSegments: cameraSegments
                )
                Self.saveLayoutSidecar(
                    request.layoutTimeline, mode: layoutMode, duration: duration,
                    to: folder.appendingPathComponent("layout.json")
                )
                Diagnostics.log(request.layoutTimeline.report(duration: duration))
            }

            let finalURL = folder.appendingPathComponent("composite.mov")
            let title = "\(plan.id) · take \(plan.number)"
            let summary = "finished \(displayPath(for: folder)), camera:\(cameraURL != nil) "
                + "phone:\(phoneURL != nil) phoneSegments:\(describe(phoneSegments)) "
                + "clicks:\(clicks.count) pointer:\(pointerLog.samples.count) "
                + "layout:\(screenLayout.rawValue)/\(faceLayout.rawValue)/\(studioBackground.rawValue) "
                + "ownCursor:\(takeDrawsOwnCursor) zoom:\(zoomMode.rawValue)=\(request.zoom.segments.count) "
                + "layoutMode:\(layoutMode.rawValue)=\(max(0, request.layoutTimeline.stops.count - 1)) moves "
                + "keys:\(pointerLog.keys?.count ?? 0) marks:\(pointerLog.marks.count)"

            // Everything this take needs is now on disk or inside `request`, so the recorder is
            // free again straight away. The slow part (painting the overlays into composite.mov) runs
            // in the background, and the next take or the next video can start while it works.
            screenRecorder = nil
            await saveTake(
                plan: plan, folder: folder, camera: cameraURL, screen: rawURL,
                micSource: captureMicrophone ? rawURL : nil, hasClicks: !clicks.isEmpty,
                crop: nil, preview: nil, stoppedBy: stoppedByRemote ? "remote-button" : nil
            )
            // The next take lands alongside this one in the same video folder.
            if destinationFolder == nil {
                destinationFolder = folder.deletingLastPathComponent()
            }
            projectFolder = nil
            refreshDestinationName()
            settleOverlayWindows()
            phase = .idle
            startFinishJob(title: title, request: request, finalURL: finalURL,
                           byRemote: stoppedByRemote, summary: summary)
        } catch {
            Diagnostics.log(error: error, context: "stop")
            phase = .failed(error.localizedDescription)
            screenRecorder = nil
            discardEmptyProjectFolder()
            settleOverlayWindows()
        }
    }

    /// `zoom-N.json`: every zoom window with the reason it fired.
    private static func saveZoomSidecar(_ zoom: ZoomTimeline, mode: ZoomMode, to url: URL) {
        let rows: [[String: Any]] = zoom.segments.map { s in
            [
                "start": s.start, "fullFrom": s.rampInEnd, "fullTo": s.rampOutStart, "end": s.end,
                "scale": Double(s.keys.first?.scale ?? 1),
                "x": Double(s.center.x), "y": Double(s.center.y), "reason": s.reason
            ]
        }
        let object: [String: Any] = ["mode": mode.rawValue, "zooms": rows]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }

    /// `layout-N.json`: every layout stop (FACE/SPLIT/SCREEN/FOCUS) and why.
    private static func saveLayoutSidecar(_ timeline: LayoutTimeline, mode: LayoutMode, duration: Double, to url: URL) {
        let object = timeline.sidecar(mode: mode, duration: duration)
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }

    /// Throws the current take away instead of saving it, for when a take
    /// went wrong and re-recording is cheaper than editing around it. Skips
    /// the mixdown/export entirely and deletes whatever this take has
    /// written so far.
    func discard() async {
        guard phase.isActive else { return }
        pendingRemoteStop?.cancel()
        pendingRemoteStop = nil

        stopTicker()
        clickTracker.stop()
        pointerTracker.stop()
        let folder = projectFolder
        phase = .finishing

        if captureMode.usesCameraOnlyRecorder {
            _ = await cameraOnlyRecorder.stopRecording()
            shortTakeSettings = nil
            settleCameraOnlyPreview()
        } else {
            _ = try? await screenRecorder?.stop()
            screenRecorder = nil
            _ = await cameraRecorder.stopRecording()
            _ = await phoneRecorder.stopRecording()
        }

        if let folder {
            deleteTakeFiles(in: folder)
            let fm = FileManager.default
            let remaining = (try? fm.contentsOfDirectory(atPath: folder.path))?
                .filter { $0 != ".DS_Store" } ?? []
            if remaining.isEmpty {
                try? fm.removeItem(at: folder)
            }
        }

        Diagnostics.log("discarded take\(folder.map { " in \(displayPath(for: $0))" } ?? "")")
        projectFolder = nil
        phase = .idle
        elapsed = 0
        refreshDestinationName()
        settleOverlayWindows()
    }

    /// Deletes every file this take could have written. Safe to call even when
    /// some of them were never created.
    private func deleteTakeFiles(in folder: URL) {
        let names = [
            "take.mov", "screen.mov", "iphone.mov", "mic.wav", "short.mov",
            "clicks.json", "cursor.json", "zoom.json", "layout.json",
            "composite.mov", "take.json"
        ]
        for name in names {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Drops the overlay windows that were only being kept alive to hold
    /// their position until the take was folded together.
    private func settleOverlayWindows() {
        if !phoneEnabled {
            phoneWindow?.orderOut(nil)
            phoneWindow = nil
        }
        if !cameraEnabled {
            bubbleWindow?.orderOut(nil)
            bubbleWindow = nil
        }
        reconcilePhone()
        reconcileCamera()
    }

    /// Segment list for the log, so "the phone didn't show up" can be
    /// answered from the log alone next time.
    private func describe(_ segments: [ClipSegment]) -> String {
        guard !segments.isEmpty else { return "none" }
        return segments
            .map { String(format: "%.1f-%.1f", $0.start, $0.end) }
            .joined(separator: ",")
    }

    func reset() {
        phase = .idle
        elapsed = 0
        refreshDestinationName()
    }

    func revealLastRecording() {
        guard let url = lastFinalURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Finishing a screen take in the background

    /// Painting the overlays into composite.mov takes minutes on a long take. Blocking on it
    /// would stop you recording the next part of the same video, so a finished take becomes a
    /// job here, the recorder is free at once, and jobs run one after another (two 4K exports
    /// at once would only slow each other and any take being recorded).
    struct FinishJob: Identifiable, Equatable {
        enum State: Equatable {
            case working(Double)
            case done(URL)
            case failed(String)
        }
        let id = UUID()
        let title: String
        var state: State = .working(0)
    }

    @Published private(set) var finishJobs: [FinishJob] = []
    private var finishTail: Task<Void, Never>?

    /// Takes whose composite.mov is not written yet. Quitting now would lose them.
    var finishingCount: Int {
        finishJobs.filter { if case .working = $0.state { return true } else { return false } }.count
    }

    private func startFinishJob(title: String, request: Mixdown.Request, finalURL: URL,
                                byRemote: Bool, summary: String) {
        let job = FinishJob(title: title)
        finishJobs.append(job)
        runFinishJob(job.id, request: request, finalURL: finalURL, byRemote: byRemote, summary: summary)
    }

    /// After a button stop: cut the reaching moment off the end of the file.
    private func trimAfterRemoteStop(_ byRemote: Bool, final finalURL: URL) async {
        guard byRemote else { return }
        await TailTrim.trim(finalURL, seconds: TailTrim.remoteTotalSeconds)
    }

    private func runFinishJob(_ id: UUID, request: Mixdown.Request, finalURL: URL,
                              byRemote: Bool, summary: String) {
        setFinishState(id, .working(0))
        let previous = finishTail
        finishTail = Task(priority: .utility) { [weak self] in
            await previous?.value
            let throttle = ProgressThrottle()
            do {
                try await Mixdown.compose(request, to: finalURL, progress: { fraction in
                    guard throttle.shouldReport(fraction) else { return }
                    Task { @MainActor [weak self] in self?.setFinishState(id, .working(fraction)) }
                })
                await self?.trimAfterRemoteStop(byRemote, final: finalURL)
                TakeManifest.setFile("composite", finalURL.lastPathComponent, in: finalURL.deletingLastPathComponent())
                await MainActor.run {
                    guard let self else { return }
                    self.setFinishState(id, .done(finalURL))
                    Diagnostics.log(summary)
                    // Only touch the main status line when nothing else is going on.
                    if self.phase == .idle || { if case .finished = self.phase { return true } else { return false } }() {
                        self.lastFinalURL = finalURL
                        self.phase = .finished(finalURL)
                    }
                }
            } catch {
                Diagnostics.log(error: error, context: "finish")
                await MainActor.run {
                    self?.setFinishState(id, .failed(error.localizedDescription))
                    self?.finishRetries[id] = { [weak self] in
                        self?.runFinishJob(id, request: request, finalURL: finalURL,
                                           byRemote: byRemote, summary: summary)
                    }
                }
            }
        }
    }

    private var finishRetries: [UUID: () -> Void] = [:]

    private func setFinishState(_ id: UUID, _ state: FinishJob.State) {
        guard let i = finishJobs.firstIndex(where: { $0.id == id }) else { return }
        finishJobs[i].state = state
    }

    func retryFinish(_ job: FinishJob) {
        guard case .failed = job.state, let retry = finishRetries.removeValue(forKey: job.id) else { return }
        retry()
    }

    func dismissFinishJob(_ job: FinishJob) {
        finishRetries[job.id] = nil
        finishJobs.removeAll { $0.id == job.id }
    }

    func revealFinishJob(_ job: FinishJob) {
        guard case .done(let url) = job.state else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Ticker

    private var tickerStartedAt = Date()

    private func startTicker() {
        tickerStartedAt = Date()
        ticker = Timer.publish(every: 0.2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                // Camera-only takes show wall time since Record: the media clock can
                // be anchored on a stray first frame with a foreign timebase (22 h bug).
                self.elapsed = self.captureMode.usesCameraOnlyRecorder
                    ? Date().timeIntervalSince(self.tickerStartedAt)
                    : self.clock.elapsedSeconds
            }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    static func timeString(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}


/// Lets a progress callback that fires for every video frame through only when it moved a
/// whole percent, so the UI is not flooded with 60 updates a second.
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1.0
    func shouldReport(_ value: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if value >= 1 || value - last >= 0.01 { last = value; return true }
        return false
    }
}
