import AppKit
import SwiftUI

/// Script near the lens so you can read while looking down the camera. Excluded from capture
/// like every other Studio Recorder window, so it is invisible in the take.
///
/// Two modes. "Follow my voice" (default) shows the script box by box and moves on
/// as speech recognition hears you; "Auto speed" is the old fixed-speed scroll. Where it sits
/// is your choice (`PrompterPosition`), remembered between launches.
@MainActor
final class TeleprompterWindow {

    let model = TeleprompterModel()
    private var panel: NSPanel?
    private var screen: NSScreen?
    private var applying = false
    private var observers: [NSObjectProtocol] = []

    private static let sizeKey = "prompterSize"
    private static let frameKey = "prompterFrame"

    var isVisible: Bool { panel != nil }

    init() {
        model.positionChanged = { [weak self] in self?.applyPosition() }
        model.speechSettingsChanged = { [weak self] in self?.syncSpeech() }
        model.beginCameraSpot = { [weak self] in self?.beginCameraSpot() }
    }

    func show(on screen: NSScreen) {
        guard panel == nil else { return }
        self.screen = screen

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 300),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar   // above the menu bar, so a camera spot in the notch works
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Below this, the control row no longer fits and gets clipped by the panel's own edge.
        panel.minSize = NSSize(width: 560, height: 200)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.contentView = NSHostingView(rootView: TeleprompterView(model: model))
        self.panel = panel
        applyPosition()
        panel.orderFrontRegardless()

        // A drag or a resize by hand = "I put it here": remembered as the Free position.
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification] {
            observers.append(center.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.userMovedPanel() }
            })
        }
        syncSpeech()
    }

    func hide() {
        model.isScrolling = false
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        spotMarker?.close(); spotMarker = nil
        panel?.orderOut(nil)
        panel = nil
        SpeechFollowHub.shared.setWanted(false)
        model.speechStatus = ""
    }

    func toggle(on screen: NSScreen) {
        if isVisible { hide() } else { show(on: screen) }
    }

    /// Follow mode listens only while the prompter is on screen.
    func syncSpeech() {
        guard isVisible, model.mode == .follow else {
            SpeechFollowHub.shared.setWanted(false)
            model.speechStatus = ""
            return
        }
        let hub = SpeechFollowHub.shared
        hub.onHeard = { [weak model] text in model?.hear(text) }
        hub.onStatus = { [weak model] text in model?.speechStatus = text }
        hub.setWanted(true, words: TeleprompterScript.contextualWords(model.text))
    }

    // MARK: Position

    private var storedSize: NSSize {
        if let s = UserDefaults.standard.string(forKey: Self.sizeKey) {
            let size = NSSizeFromString(s)
            if size.width >= 560, size.height >= 200 { return size }
        }
        return NSSize(width: 780, height: 300)
    }

    func applyPosition() {
        guard let panel, let screen = screen ?? NSScreen.main else { return }
        let full = screen.frame, visible = screen.visibleFrame
        var size = storedSize
        size.width = min(size.width, full.width - 16)
        size.height = min(size.height, visible.height - 16)
        let notchHalf: CGFloat = 110   // clear of the camera housing
        var origin: NSPoint
        switch model.position {
        case .topCenter:
            origin = NSPoint(x: full.midX - size.width / 2, y: visible.maxY - size.height - 2)
        case .left:
            size.width = min(size.width, max(420, full.midX - notchHalf - full.minX - 8))
            origin = NSPoint(x: full.midX - notchHalf - size.width, y: visible.maxY - size.height - 2)
        case .right:
            size.width = min(size.width, max(420, full.maxX - full.midX - notchHalf - 8))
            origin = NSPoint(x: full.midX + notchHalf, y: visible.maxY - size.height - 2)
        case .camera:
            let rc = PrompterLayout.readCentre(fontSize: model.fontSize)
            let f = CameraPlacement.frame(spot: cameraSpotPoint(on: screen), side: model.cameraSide,
                                          size: size, readCentre: rc, screen: full)
            size = f.size
            origin = f.origin
        case .custom:
            if let s = UserDefaults.standard.string(forKey: Self.frameKey) {
                let f = NSRectFromString(s)
                if f.width >= 560, f.height >= 200 {
                    size = f.size
                    origin = f.origin
                    // keep it reachable if the screen layout changed
                    origin.x = min(max(origin.x, full.minX - size.width + 80), full.maxX - 80)
                    origin.y = min(max(origin.y, full.minY), full.maxY - 60)
                    break
                }
            }
            origin = NSPoint(x: full.midX - size.width / 2, y: visible.maxY - size.height - 2)
        }
        applying = true
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
        applying = false
    }

    // MARK: Camera spot

    private static let spotKey = "prompterCameraSpot"
    private var spotMarker: CameraSpotMarker?

    /// The camera lens in screen coordinates. Stored as fractions of the screen (x from the left,
    /// y from the top). Default: top centre, where a MacBook camera is.
    func cameraSpotPoint(on screen: NSScreen) -> CGPoint {
        var fx = 0.5, fy = 0.0
        if let s = UserDefaults.standard.string(forKey: Self.spotKey) {
            let p = NSPointFromString(s)
            fx = Double(p.x); fy = Double(p.y)
        }
        let f = screen.frame
        return CGPoint(x: f.minX + CGFloat(fx) * f.width, y: f.maxY - CGFloat(fy) * f.height)
    }

    private func storeCameraSpot(_ p: CGPoint, on screen: NSScreen) {
        let f = screen.frame
        let fx = min(max((p.x - f.minX) / f.width, 0), 1)
        let fy = min(max((f.maxY - p.y) / f.height, 0), 1)
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: fx, y: fy)), forKey: Self.spotKey)
    }

    /// Shows a crosshair you drag onto your camera lens. The prompter follows it live; Done keeps it.
    func beginCameraSpot() {
        guard let screen = screen ?? NSScreen.main else { return }
        spotMarker?.close()
        model.setPositionWithoutMoving(.camera)
        let marker = CameraSpotMarker(model: model, start: cameraSpotPoint(on: screen))
        marker.onMove = { [weak self] p in
            guard let self, let screen = self.screen ?? NSScreen.main else { return }
            self.storeCameraSpot(p, on: screen)
            self.applyPosition()
        }
        marker.onDone = { [weak self] in self?.spotMarker = nil }
        spotMarker = marker
        marker.show()
        applyPosition()
    }

    private func userMovedPanel() {
        guard !applying, let panel else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.frameKey)
        UserDefaults.standard.set(NSStringFromSize(panel.frame.size), forKey: Self.sizeKey)
        if model.position != .custom {
            applying = true            // do not re-apply a preset over what was just dragged
            model.setPositionWithoutMoving(.custom)
            applying = false
        }
    }
}

enum PrompterPosition: String, CaseIterable, Identifiable {
    case topCenter, left, right, custom, camera
    var id: String { rawValue }
    var label: String {
        switch self {
        case .topCenter: return "Top centre, under the camera"
        case .left:      return "Left of the camera"
        case .right:     return "Right of the camera"
        case .custom:    return "Free (where I put it)"
        case .camera:    return "At my camera spot"
        }
    }
    var short: String {
        switch self {
        case .topCenter: return "Top centre"
        case .left:      return "Left"
        case .right:     return "Right"
        case .custom:    return "Free"
        case .camera:    return "Camera spot"
        }
    }
    var symbol: String {
        switch self {
        case .topCenter: return "rectangle.center.inset.filled"
        case .left:      return "rectangle.lefthalf.inset.filled"
        case .right:     return "rectangle.righthalf.inset.filled"
        case .custom:    return "arrow.up.and.down.and.arrow.left.and.right"
        case .camera:    return "camera.viewfinder"
        }
    }
}

enum PrompterMode: String, CaseIterable, Identifiable {
    case follow, auto
    var id: String { rawValue }
    var label: String { self == .follow ? "Follow my voice" : "Auto speed" }
}

@MainActor
final class TeleprompterModel: ObservableObject {
    @Published var text: String = "" { didSet { if text != oldValue { reloadScript() } } }
    /// Cue lists show their leading keyword as a label. `.script` unless a
    /// long-form handoff says otherwise.
    @Published var style: TeleprompterScript.Style = .script { didSet { if style != oldValue { reloadScript() } } }
    @Published var isScrolling = false
    /// Points per second.
    @Published var speed: Double = 14
    @Published var fontSize: Double = {
        let saved = UserDefaults.standard.double(forKey: "prompterFontSize")
        return saved >= 18 ? saved : 32
    }() { didSet {
        UserDefaults.standard.set(fontSize, forKey: "prompterFontSize")
        if position == .camera, fontSize != oldValue { positionChanged?() }   // reading line height changed
    } }

    // MARK: Follow my voice

    @Published var mode: PrompterMode = PrompterMode(rawValue: UserDefaults.standard.string(forKey: "prompterMode") ?? "") ?? .follow {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "prompterMode")
            if mode != oldValue { isScrolling = false; speechSettingsChanged?() }
        }
    }
    @Published var position: PrompterPosition = PrompterPosition(rawValue: UserDefaults.standard.string(forKey: "prompterPosition") ?? "") ?? .topCenter {
        didSet {
            UserDefaults.standard.set(position.rawValue, forKey: "prompterPosition")
            if position != oldValue, !skipPositionCallback { positionChanged?() }
        }
    }
    @Published var speechStatus = ""
    /// "light" = a cream page, "dark" = its dark variant.
    @Published var theme: String = UserDefaults.standard.string(forKey: "prompterTheme") ?? "light" {
        didSet { UserDefaults.standard.set(theme, forKey: "prompterTheme") }
    }
    /// Page background opacity 0...1 (text stays opaque). Remembered.
    @Published var bgOpacity: Double = {
        let d = UserDefaults.standard
        return d.object(forKey: "prompterBgOpacity") == nil ? 0.55 : min(max(d.double(forKey: "prompterBgOpacity"), 0), 1)
    }() { didSet { UserDefaults.standard.set(bgOpacity, forKey: "prompterBgOpacity") } }
    @Published var cameraSide: CameraSide = CameraSide(rawValue: UserDefaults.standard.string(forKey: "prompterCameraSide") ?? "") ?? .under {
        didSet {
            UserDefaults.standard.set(cameraSide.rawValue, forKey: "prompterCameraSide")
            if cameraSide != oldValue { positionChanged?() }
        }
    }
    /// Asked by the view's menu; the window shows the draggable crosshair.
    var beginCameraSpot: (() -> Void)?
    /// Called when the clicker/keys want the last status line refreshed.
    var panelLineHeight: CGFloat { CGFloat(fontSize) * PrompterLayout.lineHeightFactor }
    var dictationTip: String { "Faster + offline: turn on Dictation in System Settings > Keyboard" }
    /// Bumped whenever the follower moves, so the view redraws.
    @Published var revision = 0
    let follower = ScriptFollower()
    var positionChanged: (() -> Void)?
    var speechSettingsChanged: (() -> Void)?
    private var skipPositionCallback = false

    func setPositionWithoutMoving(_ p: PrompterPosition) {
        skipPositionCallback = true
        position = p
        skipPositionCallback = false
    }

    private func reloadScript() {
        follower.load(text: text, style: style)
        revision += 1
        speechSettingsChanged?()
    }

    /// Recogniser transcript from `SpeechFollowHub`.
    func hear(_ transcript: String) {
        guard mode == .follow else { return }
        if follower.hear(transcript) { revision += 1 }
    }

    /// Next (+1) / previous (-1) box.
    func stepBox(_ delta: Int) {
        if mode == .follow {
            follower.step(delta)
            revision += 1
        } else {
            scroll(by: Double(delta) * fontSize * 4)
        }
    }
    @Published var offset: Double = 0

    /// Height of the laid-out script, measured by the view. Bounds manual
    /// scrolling and stops the automatic scroll running off into blank space
    /// once the script has finished.
    @Published var contentHeight: Double = 0

    /// Headroom above the start, so the first line can be nudged down clear of the top edge. /// generous on purpose. At 40pt this was barely more than one line at a large font size,
    /// so reaching the floor didn't mean "the true start is visible", it just meant "no more
    /// slack", which reads as a stuck scrollbar, not as "you've arrived".
    private let overscroll: Double = 300

    var maxOffset: Double { max(0, contentHeight - 40) }

    private func clamp(_ value: Double) -> Double {
        min(max(value, -overscroll), maxOffset)
    }

    /// Manual scroll, a button click or the wheel. Pauses auto-scroll first. Without this, the
    /// 30fps auto-advance timer (`isScrolling`) fights every manual nudge: scroll up a line, and
    /// a fraction of a second later the timer pushes forward again, undoing it. From the outside
    /// that looks exactly like "I try to go up and it does not work", the offset isn't stuck,
    /// it's being pulled back forward as fast as it's pushed back.
    func scroll(by delta: Double) {
        isScrolling = false
        offset = clamp(offset + delta)
    }

    /// The auto-advance timer's own forward step, deliberately NOT `scroll(by:)`, which would
    /// pause `isScrolling` on its very first tick and make Play stop itself after one frame.
    func autoAdvance(by delta: Double) {
        offset = clamp(offset + delta)
    }

    /// Jumps to the true beginning and stops the timer, same reasoning as `scroll(by:)`: a
    /// reset that auto-scroll immediately resumes advancing past isn't a reset at all.
    func restart() {
        isScrolling = false
        offset = 0
        follower.restart()
        revision += 1
    }
}

/// Soft halo behind text so it stays readable on any app showing through: light on the cream
/// page, dark on the dark page; grows as the background gets more transparent (t = 0...1).
struct HaloModifier: ViewModifier {
    let t: Double
    let dark: Bool
    func body(content: Content) -> some View {
        let c = dark ? Color.black : Color(red: 0xF5 / 255, green: 0xED / 255, blue: 0xD8 / 255)
        content
            .shadow(color: c.opacity(0.35 + 0.65 * t), radius: 1 + 2 * t)
            .shadow(color: c.opacity(t * 0.95), radius: 3 + 6 * t)
            .shadow(color: c.opacity(t * 0.8), radius: 6 + 10 * t)
    }
}

struct TeleprompterView: View {
    @ObservedObject var model: TeleprompterModel

    private let tick = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    private static let voiceoverGreen = Color(red: 0.62, green: 0.80, blue: 0.72)

    private var segments: [TeleprompterScript.Segment] {
        TeleprompterScript.segments(model.text)
    }

    /// A line the voiceover speaks. You stop here, so this is styled to read as an instruction
    /// to stop, not as more script: different colour, smaller, boxed, and captioned.
    private func voiceoverBlock(_ text: String) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                Circle()
                    .fill(Self.voiceoverGreen)
                    .frame(width: 8, height: 8)
                Text("DON'T SAY THIS. PAUSE, THE VOICEOVER SPEAKS")
                    .font(.system(size: max(10, model.fontSize * 0.36), weight: .bold, design: .rounded))
                    .tracking(0.8)
            }
            .foregroundStyle(Self.voiceoverGreen.opacity(0.9))

            Text(text)
                .font(.system(size: model.fontSize * 0.74, weight: .semibold, design: .rounded))
                .foregroundStyle(Self.voiceoverGreen)
                .lineSpacing(5)
                .lineLimit(nil)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Self.voiceoverGreen.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Self.voiceoverGreen.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                )
        )
    }

    private static let cueGold = Color(red: 0.83, green: 0.68, blue: 0.35)

    /// A hand-gesture cue (`[PINCH]`): small, dim, a hand icon, so it reads as
    /// something to do and never as words to say.
    private func gestureTag(_ cue: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.raised.fill")
            Text(cue).tracking(1.4)
        }
        .font(.system(size: max(10, model.fontSize * 0.38), weight: .bold, design: .rounded))
        .foregroundStyle(.white.opacity(0.42))
    }

    /// One cue on its own line: the keyword is a small, dim, tracked label in a fixed column
    /// (so the cue text lines up down the page), then the cue itself at full size. SAY is the
    /// one cue with exact words, so its label is gold and its text is quoted as written.
    private func cueRow(_ cue: TeleprompterScript.CueLine) -> some View {
        let isSay = cue.keyword == "SAY"
        return HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(cue.keyword)
                .font(.system(size: max(10, model.fontSize * 0.38), weight: .bold, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(isSay ? Self.cueGold.opacity(0.9) : .white.opacity(0.42))
                .frame(width: max(56, model.fontSize * 2.3), alignment: .leading)
            Text(cue.text)
                .font(.system(size: model.fontSize, weight: isSay ? .semibold : .medium, design: .rounded))
                .foregroundStyle(.white)
                .lineSpacing(6)
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var body: some View {
        if model.mode == .follow { followBody } else { autoBody }
    }

    // MARK: Auto speed (the original fixed-speed scroll)

    private var autoBody: some View {
        // `Text` needs `.fixedSize(vertical: true)` below so a long script
        // reports its true full height instead of truncating with "…". Left
        // unchecked, that taller-than-the-panel Text also inflates the
        // ZStack itself, background, clip shape and all, which is what
        // made the panel balloon and flicker. Reading the panel's real size
        // once here and explicitly pinning the ZStack to it keeps the box
        // exactly the size it's supposed to be; only the Text inside is
        // allowed to run taller, and the pinned clipShape below is what
        // hides the overflow for scrolling to reveal.
        GeometryReader { panel in
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.black.opacity(0.78))

                if model.text.isEmpty {
                    Text("Paste your script in the Studio Recorder window.")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(24)
                } else {
                    // Segments rather than one Text: a voiceover line has to look
                    // nothing like the lines you read, or you will read it by reflex and
                    // burn the take.
                    VStack(spacing: model.fontSize * 0.7) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                            if segment.isVoiceover {
                                voiceoverBlock(segment.text)
                            } else {
                                ForEach(Array(TeleprompterScript.blocks(segment.text, style: model.style).enumerated()), id: \.offset) { _, block in
                                    switch block {
                                    case .paragraph(let text):
                                        // Whole phrases per line, not a fixed-width wrap.
                                        Text(TeleprompterScript.phraseLayout(text, maxChars: TeleprompterScript.charsPerLine(
                                            width: panel.size.width - 56, fontSize: model.fontSize)))
                                            .font(.system(size: model.fontSize, weight: .medium, design: .rounded))
                                            .foregroundStyle(.white)
                                            .lineSpacing(8)
                                            .lineLimit(nil)
                                            .multilineTextAlignment(model.style == .cues ? .leading : .center)
                                            .frame(maxWidth: .infinity, alignment: model.style == .cues ? .leading : .center)
                                    case .cue(let cue):
                                        cueRow(cue)
                                    case .gesture(let cue):
                                        gestureTag(cue)
                                            .frame(maxWidth: .infinity, alignment: model.style == .cues ? .leading : .center)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 28)
                    .frame(width: panel.size.width, alignment: .center)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.onChange(of: proxy.size.height, initial: true) { _, height in
                                model.contentHeight = height
                            }
                        }
                    )
                    .offset(y: 30 - model.offset)
                }
            }
            // `.top`, not the default centre: a script taller than the panel makes the ZStack
            // taller than this frame, and centring it hides the first lines above the edge. // a cue list would open halfway down.
            .frame(width: panel.size.width, height: panel.size.height, alignment: .top)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            // Overlays, not ZStack siblings: an overlay is sized to match
            // the view it's laid over and never itself feeds back into that
            // view's size. As ZStack siblings, the transport row and the
            // scroll-catching layer were competing in the same layout
            // negotiation as the (now much taller, via fixedSize) script
            // text and were getting squeezed out of the pinned frame
            // entirely instead of just sitting on top of it.
            .overlay(ScrollCatcher { model.scroll(by: $0) })
            .overlay(controls)
        }
        .onReceive(tick) { _ in
            guard model.isScrolling else { return }
            // Stops at the end of the script instead of scrolling on into
            // nothing, which used to make it look like the text had vanished.
            guard model.offset < model.maxOffset else {
                model.isScrolling = false
                return
            }
            model.autoAdvance(by: model.speed / 30.0)
        }
    }


    // MARK: Follow my voice (present-mode look)

    private static let actionYellow = Color(red: 0.98, green: 0.80, blue: 0.20)

    /// The reader palette: a cream page or a dark page.
    private struct Palette {
        let bg: Color, ink: Color, band: Color, cue: Color, chip: Color, ui: Color
        static let light = Palette(
            bg: Color(red: 0xF5 / 255, green: 0xED / 255, blue: 0xD8 / 255),
            ink: Color(red: 0x14 / 255, green: 0x09 / 255, blue: 0x03 / 255),
            band: Color(red: 207 / 255, green: 148 / 255, blue: 136 / 255).opacity(0.30),
            cue: Color(red: 0xB8 / 255, green: 0x67 / 255, blue: 0x5A / 255),
            chip: Color(red: 245 / 255, green: 237 / 255, blue: 216 / 255).opacity(0.94),
            ui: Color(red: 0x2C / 255, green: 0x15 / 255, blue: 0x08 / 255))
        static let dark = Palette(
            bg: Color(red: 0x0E / 255, green: 0x0B / 255, blue: 0x09 / 255),
            ink: Color(red: 1, green: 0xF6 / 255, blue: 0xEA / 255),
            band: Color(red: 231 / 255, green: 149 / 255, blue: 196 / 255).opacity(0.16),
            cue: Color(red: 0xE7 / 255, green: 0x95 / 255, blue: 0xC4 / 255),
            chip: Color(red: 28 / 255, green: 22 / 255, blue: 18 / 255).opacity(0.94),
            ui: Color(red: 0xF5 / 255, green: 0xED / 255, blue: 0xD8 / 255))
    }
    private var pal: Palette { model.theme == "dark" ? .dark : .light }

    private var modeMenu: some View {
        Menu {
            ForEach(PrompterMode.allCases) { m in
                Button((model.mode == m ? "\u{2713} " : "") + m.label) { model.mode = m }
            }
            Divider()
            Button((model.theme == "light" ? "\u{2713} " : "") + "Cream page") { model.theme = "light" }
            Button((model.theme == "dark" ? "\u{2713} " : "") + "Dark page") { model.theme = "dark" }
            Divider()
            ForEach([1.0, 0.75, 0.55, 0.35, 0.2], id: \.self) { v in
                Button((abs(model.bgOpacity - v) < 0.05 ? "\u{2713} " : "") + "Background \(Int(v * 100))%") { model.bgOpacity = v }
            }
            Divider()
            Text(model.dictationTip)
        } label: {
            Label(model.mode == .follow ? "Follow" : "Auto", systemImage: model.mode == .follow ? "waveform" : "arrow.down.to.line")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Follow my voice, or scroll at a fixed speed. \(model.dictationTip)")
    }

    private var positionMenu: some View {
        Menu {
            ForEach(PrompterPosition.allCases.filter { $0 != .camera }) { p in
                Button((model.position == p ? "\u{2713} " : "") + p.label) { model.position = p }
            }
            Divider()
            ForEach(CameraSide.allCases, id: \.self) { side in
                Button((model.position == .camera && model.cameraSide == side ? "\u{2713} " : "") + side.label + " (my spot)") {
                    model.cameraSide = side
                    model.position = .camera
                }
            }
            Button("Set camera spot\u{2026}") { model.beginCameraSpot?() }
        } label: {
            Label(model.position.short, systemImage: model.position.symbol)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Where the prompter sits relative to the camera. Set camera spot: drag a cross onto your lens.")
    }

    /// One line of words with the already-said ones stepped back .
    private func lineText(_ box: FollowBox, _ range: Range<Int>, read: Int, current: Bool) -> Text {
        var out = AttributedString()
        for i in range {
            let w = box.words[i]
            var piece = AttributedString(w.text + (i == range.upperBound - 1 ? "" : " "))
            piece.foregroundColor = (current && i < read) ? pal.ink.opacity(0.5) : pal.ink
            out.append(piece)
        }
        return Text(out)
    }

    private func readerFont(_ scale: Double = 1, weight: Font.Weight = .medium) -> Font {
        .system(size: model.fontSize * scale, weight: weight)
    }

    @ViewBuilder
    private func boxView(_ b: BoxLayout, focus: Int, read: Int, colW: CGFloat) -> some View {
        let box = model.follower.boxes[b.index]
        // Said-and-gone .22, still to come .58, the one being read 1.
        let isCur = b.index == focus
        let spokenFocusOrdinal = focus
        let opacity: Double = isCur ? 1 : (b.index < spokenFocusOrdinal ? 0.22 : 0.58 + 0.27 * (1 - model.bgOpacity))
        switch box.kind {
        case .spoken:
            HStack(alignment: .top, spacing: 0) {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(isCur ? pal.cue : pal.ink.opacity(0.16))
                    .frame(width: 5, height: max(0, b.height - model.fontSize * 0.8 - 4))
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 0) {
                    if let g = box.gesture {
                        HStack(spacing: 5) {
                            Image(systemName: "hand.raised.fill")
                            Text(g).tracking(1.2)
                        }
                        .font(.system(size: max(10, model.fontSize * 0.36), weight: .bold))
                        .foregroundStyle(pal.ink.opacity(0.5))
                        .frame(height: b.head, alignment: .center)
                    }
                    ForEach(Array(b.lines.enumerated()), id: \.offset) { _, r in
                        lineText(box, r, read: read, current: isCur)
                            .font(readerFont())
                            .tracking(model.fontSize * 0.005)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(width: colW, height: model.panelLineHeight, alignment: .leading)
                    }
                }
                .padding(.leading, 15)
            }
            .opacity(opacity)
            .modifier(HaloModifier(t: 1 - model.bgOpacity, dark: model.theme == "dark"))
        case .action(let keyword):
            VStack(spacing: 2) {
                Text(keyword)
                    .font(.system(size: max(10, model.fontSize * 0.4), weight: .heavy))
                    .tracking(1.6)
                    .foregroundStyle(.black.opacity(0.6))
                Text(box.text)
                    .font(.system(size: model.fontSize * PrompterLayout.cardFontFactor, weight: .semibold))
                    .foregroundStyle(.black)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .minimumScaleFactor(0.6)
            }
            .padding(.horizontal, 18)
            .frame(width: colW + 20, height: b.cardHeight)
            .background(RoundedRectangle(cornerRadius: 12).fill(Self.actionYellow.opacity(0.8 + 0.2 * model.bgOpacity)))
            .padding(.leading, 5)
            .opacity(isCur ? 1 : (b.index < focus ? 0.3 : 0.8))
        case .voiceover:
            VStack(spacing: 4) {
                HStack(spacing: 7) {
                    Circle().fill(Self.voiceoverGreen).frame(width: 9, height: 9)
                    Text("DON'T SAY THIS. PAUSE, THE VOICEOVER SPEAKS")
                        .font(.system(size: max(10, model.fontSize * 0.36), weight: .bold))
                        .tracking(0.8)
                }
                .foregroundStyle(Self.voiceoverGreen)
                Text(box.text)
                    .font(.system(size: model.fontSize * 0.8, weight: .semibold))
                    .foregroundStyle(Self.voiceoverGreen)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.6)
            }
            .padding(.horizontal, 18)
            .frame(width: colW + 20, height: b.cardHeight)
            .background(RoundedRectangle(cornerRadius: 12).fill(Self.voiceoverGreen.opacity(0.18 + 0.5 * (1 - model.bgOpacity))))
            .padding(.leading, 5)
            .opacity(isCur ? 1 : 0.7)
        }
    }

    private var followBody: some View {
        let _ = model.revision
        let f = model.follower
        return GeometryReader { panel in
            let colW = CGFloat(PrompterLayout.columnWidth(panelWidth: Double(panel.size.width)))
            let layout = PrompterLayout.build(boxes: f.boxes, fontSize: model.fontSize, columnWidth: Double(colW))
            let read = f.wordsRead(in: f.focus)
            let anchor = layout.readY(focus: f.focus, wordsRead: read)
            let readC = PrompterLayout.readCentre(fontSize: model.fontSize)
            let lh = layout.lineHeight
            let barH: CGFloat = 46          // the control bar lives in its own strip: text never runs under it
            let usableH = max(60, panel.size.height - barH)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14).fill(pal.bg.opacity(model.bgOpacity))

                if f.isEmpty {
                    Text("No script yet. Paste one in the Studio Recorder window, or send one from the Studio app.")
                        .font(.system(size: 15))
                        .foregroundStyle(pal.ink.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(28)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // The reading band, pinned at the reading line with the
                    // cue triangle, and a thin "eyes here" line on its top edge.
                    RoundedRectangle(cornerRadius: 10)
                        .fill(f.boxes.indices.contains(f.focus) && f.boxes[f.focus].isSpoken ? pal.band : .clear)
                        .frame(width: panel.size.width - PrompterLayout.columnLeft + 14, height: lh + 10)
                        .offset(x: PrompterLayout.columnLeft - 14, y: readC - lh / 2 - 5)
                    Rectangle()
                        .fill(pal.cue.opacity(0.7))
                        .frame(width: panel.size.width - 2 * 14, height: 1.5)
                        .offset(x: 14, y: readC - lh / 2 - 5)
                    Path { p in
                        p.move(to: CGPoint(x: 7, y: readC - 9))
                        p.addLine(to: CGPoint(x: 7, y: readC + 9))
                        p.addLine(to: CGPoint(x: 18, y: readC))
                        p.closeSubpath()
                    }
                    .fill(pal.cue)

                    ZStack(alignment: .topLeading) {
                        ZStack(alignment: .topLeading) {
                            ForEach(layout.boxes, id: \.index) { b in
                                boxView(b, focus: f.focus, read: read, colW: colW)
                                    .offset(x: 0, y: b.y)
                            }
                        }
                        .frame(width: panel.size.width, height: max(1, layout.totalHeight), alignment: .topLeading)
                        .padding(.leading, PrompterLayout.columnLeft - 20)
                        .frame(width: panel.size.width, alignment: .leading)
                        .offset(y: readC - anchor)
                        .animation(.easeOut(duration: 0.38), value: anchor)
                        .animation(.easeOut(duration: 0.25), value: f.focus)
                    }
                    .frame(width: panel.size.width, height: usableH, alignment: .topLeading)
                    .clipped()
                    // Lines that have scrolled above the reading line dissolve instead of
                    // showing half-cut against the top edge .
                    .mask(
                        LinearGradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .clear, location: Double((PrompterLayout.topGap - 5) / max(1, usableH))),
                            .init(color: .black, location: Double((PrompterLayout.topGap + 2) / max(1, usableH))),
                            .init(color: .black, location: 1),
                        ], startPoint: .top, endPoint: .bottom)
                    )
                    if f.finished && f.focus == f.boxes.count - 1 {
                        Text("End of script")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(pal.ink.opacity(0.4))
                            .frame(maxWidth: .infinity)
                            .offset(y: readC + lh)
                    }
                }
            }
            .frame(width: panel.size.width, height: panel.size.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(alignment: .bottom) { followControls }
        }
    }

    private var followControls: some View {
        HStack(spacing: 12) {
            modeMenu
            positionMenu
            Button { model.stepBox(-1) } label: { Image(systemName: "chevron.left") }
                .help("Previous box (Control-Option-Left)")
            Button { model.stepBox(1) } label: { Image(systemName: "chevron.right") }
                .help("Next box (Control-Option-Right, or hold the clicker)")
            Button { model.restart() } label: { Image(systemName: "arrow.counterclockwise") }
                .help("Back to the start")
            Image(systemName: "textformat.size").font(.system(size: 11))
            Slider(value: $model.fontSize, in: 18...54)
                .frame(width: 70)
            Image(systemName: "circle.lefthalf.filled").font(.system(size: 11))
            Slider(value: $model.bgOpacity, in: 0...1)
                .frame(width: 70)
                .help("Background opacity: the text stays solid")
            if !model.speechStatus.isEmpty {
                Text(model.speechStatus)
                    .font(.system(size: 10))
                    .foregroundStyle(model.speechStatus.hasPrefix("Listening") ? Color(red: 0.2, green: 0.55, blue: 0.3) : Color.orange)
                    .lineLimit(1)
                    .frame(maxWidth: 150, alignment: .leading)
                    .help(model.speechStatus)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(pal.ui.opacity(0.9))
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(pal.chip, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
        .padding(.bottom, 8)
    }

    private var controls: some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                modeMenu
                positionMenu
                Button {
                    model.isScrolling.toggle()
                } label: {
                    Image(systemName: model.isScrolling ? "pause.fill" : "play.fill")
                }
                Button {
                    model.restart()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                // A line at a time, for when the wheel is too coarse.
                Button {
                    model.scroll(by: -model.fontSize * 1.4)
                } label: {
                    Image(systemName: "chevron.up")
                }
                Button {
                    model.scroll(by: model.fontSize * 1.4)
                } label: {
                    Image(systemName: "chevron.down")
                }
                Slider(value: $model.speed, in: 10...110)
                    .frame(width: 90)
                Text("\(Int(model.speed))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.5), in: Capsule())
            .padding(.bottom, 10)
        }
    }
}

/// Turns two-finger and wheel scrolling over the script into offsets.
///
/// SwiftUI has no scroll-wheel gesture on macOS, and wrapping the text in a
/// real ScrollView would fight the automatic scroll for control of the same
/// offset. This is the smaller piece: report the delta, let the model own the
/// position.
private struct ScrollCatcher: NSViewRepresentable {
    var onScroll: (Double) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onScroll = onScroll
    }

    final class CatcherView: NSView {
        var onScroll: ((Double) -> Void)?

        override func scrollWheel(with event: NSEvent) {
            var delta = event.scrollingDeltaY
            // A notched wheel reports whole lines; a trackpad reports points.
            if !event.hasPreciseScrollingDeltas { delta *= 10 }
            onScroll?(-Double(delta))
        }

        // Deliberately no mouseDown override. Clicks fall through to the
        // window, which is what keeps `isMovableByWindowBackground` working. // swallow them here and the panel could no longer be dragged anywhere
        // on screen.
    }
}
