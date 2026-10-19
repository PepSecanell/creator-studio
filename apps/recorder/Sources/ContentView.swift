import SwiftUI
import ScreenCaptureKit

struct ContentView: View {
    @EnvironmentObject private var controller: RecordingController
    @State private var showingDiscardConfirmation = false

    /// The brand accent (falls back to a soft gold without a brand).
    private var gold: Color { controller.brand.accentColor }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 14)

            Divider().opacity(0.25)

            // Camera-only takes never touch ScreenCaptureKit, so a missing
            // Screen Recording grant must not block that mode.
            if !controller.hasScreenPermission && controller.captureMode == .screen {
                VStack(spacing: 14) {
                    permissionPrompt
                    modeSection
                }
                .padding(20)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        permissionsBanner
                        modeSection
                        sectionDivider

                        if controller.captureMode == .cameraOnly {
                            cameraOnlySection
                            sectionDivider
                            teleprompterSection
                        } else if controller.captureMode == .short {
                            shortSection
                            sectionDivider
                            teleprompterSection
                        } else {
                            screenSection
                            sectionDivider
                            cameraSection
                            sectionDivider
                            phoneSection
                            sectionDivider
                            motionSection
                            sectionDivider
                            teleprompterSection
                        }
                        sectionDivider
                        remoteSection
                    }
                    .padding(20)
                }
                .frame(maxHeight: 430)
            }

            Divider().opacity(0.25)

            VStack(spacing: 10) {
                transport
                statusFooter
                finishQueuePanel
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 400)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sectionDivider: some View {
        Divider().opacity(0.18)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(controller.phase == .recording ? Color(red: 0.83, green: 0.64, blue: 0.60) : gold)
                .frame(width: 9, height: 9)
            Text(controller.brand.recorderTitle)
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            if controller.phase.isActive {
                Text(RecordingController.timeString(controller.elapsed))
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundStyle(timerStyle)
            }
        }
    }

    /// Short takes: amber from 40 s, red from 60 s (short-form targets).
    private var timerStyle: AnyShapeStyle {
        if controller.phase == .paused { return AnyShapeStyle(.secondary) }
        guard controller.captureMode == .short else { return AnyShapeStyle(.primary) }
        switch ShortFraming.lengthBand(controller.elapsed) {
        case .normal: return AnyShapeStyle(.primary)
        case .amber: return AnyShapeStyle(Color(nsColor: .systemOrange))
        case .red: return AnyShapeStyle(Color(nsColor: .systemRed))
        }
    }

    // MARK: - Permission

    private var permissionPrompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Screen Recording permission needed")
                .font(.system(size: 13, weight: .semibold))
            Text("macOS has to allow Studio Recorder to see your screen. "
                 + "After granting it, quit and reopen the app.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Grant permission") {
                controller.requestScreenPermission()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Permissions banner

    /// Only appears when something the current setup needs is missing.
    /// A missing microphone grant used to surface as an unplayable file
    /// after the take; now it is visible before pressing Record.
    /// Kept visible during recording too, unlike the mic picker inside
    /// `screenSection`, which is disabled the moment a take starts. The
    /// warning matters most exactly then: it is the only sign that the take
    /// in progress is going through a headset mic instead of the Mac's own.
    @ViewBuilder
    private var permissionsBanner: some View {
        let cameraOnly = controller.captureMode.usesCameraOnlyRecorder
        let needsMic = (controller.captureMicrophone || cameraOnly)
            && controller.micPermission != .granted
        let needsCamera = (controller.cameraEnabled || cameraOnly)
            && controller.cameraPermission != .granted
        let wrongMic = (controller.captureMicrophone || cameraOnly)
            && controller.usingWorseMicrophoneThanAvailable

        if wrongMic {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Microphone: \(controller.selectedMicrophoneName ?? "a different device"). "
                     + "\(controller.bestMicrophoneName ?? "another input") is better. Switch Input.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }

        if needsMic || needsCamera {
            VStack(alignment: .leading, spacing: 8) {
                Label("Permission missing", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)

                if needsMic {
                    HStack {
                        Text("Microphone, the take would have no voice")
                            .font(.system(size: 11))
                        Spacer()
                        Button("Grant") { Task { await controller.grantMicrophone() } }
                            .controlSize(.small)
                    }
                }
                if needsCamera {
                    HStack {
                        Text("Camera, the bubble would be empty")
                            .font(.system(size: 11))
                        Spacer()
                        Button("Grant") { Task { await controller.grantCamera() } }
                            .controlSize(.small)
                    }
                }

                Text("If macOS does not ask, tick Studio Recorder in System Settings › Privacy & Security, then quit and reopen the app.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Mode

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $controller.captureMode) {
                ForEach(RecordingController.CaptureMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            if let request = controller.activeHandoff {
                handoffBanner(request)
            }

            if controller.captureMode == .short {
                Text("Vertical 9:16 take. Each one gets its own folder in takes/shorts/ with take.mov (the full camera frame), short.mov (the 9:16 cut) and take.json.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                destinationPicker
            }

            if controller.captureMode == .cameraOnly {
                Text("Camera and microphone only. No screen, and no Screen Recording permission needed.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(controller.phase.isActive || controller.phase.isBusy)
    }

    /// "Recording: <title>" while a request from the Studio app is the destination: says which
    /// video or Short the next take belongs to, and "Not this one" lets go of it.
    private func handoffBanner(_ request: Handoff) -> some View {
        let locked = controller.phase.isActive || controller.phase.isBusy
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: request.kind == .short ? "rectangle.portrait" : "film")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(gold)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recording: \(request.title.isEmpty ? request.id : request.title)")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                    .truncationMode(.tail)
                Text("From the Studio app · \(request.mode.rawValue)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button("Not this one") { controller.ignoreHandoff() }
                .controlSize(.mini)
                .disabled(locked)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(gold.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(gold.opacity(0.4)))
        )
    }

    /// Where the next take lands. Sticky on purpose: several takes of the
    /// same video should keep going to the same folder without re-picking
    /// it every time.
    private var destinationPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Picker("Save to", selection: $controller.destinationFolder) {
                    Text("New video folder").tag(URL?.none)
                    ForEach(controller.existingFolders, id: \.self) { folder in
                        Text(folder.lastPathComponent).tag(URL?.some(folder))
                    }
                }

                Button {
                    controller.refreshDestinationName()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .help("Refresh the folder list. Picks up a folder made since the app opened.")
            }

            Text(controller.destinationFolder == nil
                 ? "The first take makes a new video folder. Every take gets its own take-N folder inside."
                 : "Extra takes go in the same video folder, as take-2, take-3, and so on.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Camera only

    private var cameraOnlySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Just me", systemImage: "person.crop.circle.fill")

            Picker("Camera", selection: $controller.selectedCameraID) {
                ForEach(controller.cameras, id: \.uniqueID) { device in
                    Text(device.localizedName).tag(Optional(device.uniqueID))
                }
            }

            cameraAudioControls

            Toggle("Mirror me", isOn: $controller.mirrorCamera)

            checkFramingButton(
                help: "A big live preview of exactly what gets recorded, with guides and tips, see if you're too close, too far, too high or badly lit before you record."
            )

            Text("Always the whole camera image, exactly as captured, no crop, no re-encode. One file straight out of the camera.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(controller.phase.isActive || controller.phase.isBusy)
    }

    // MARK: - Short

    private var shortSection: some View {
        let frame = controller.shortFrameSize
        let locked = controller.shortCropLocked
        return VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Short (9:16)", systemImage: "rectangle.portrait")

            Picker("Camera", selection: $controller.selectedCameraID) {
                ForEach(controller.cameras, id: \.uniqueID) { device in
                    Text(device.localizedName).tag(Optional(device.uniqueID))
                }
            }
            .disabled(locked)

            cameraAudioControls
                .disabled(locked)

            Toggle("Mirror the preview", isOn: $controller.mirrorCamera)
                .disabled(locked)
                .help("Shared with Just me's Mirror me. Only changes what you see while recording.")
            Toggle("Mirror the recorded Short too", isOn: $controller.shortMirrorFile)
                .disabled(locked)
                .help("Off (default): the Short is the true image, so text behind you reads the right way. Viewer view shows the file as it will be.")

            HStack(spacing: 8) {
                Button {
                    controller.isShortWindowOpen ? controller.closeShortPreview() : controller.openShortPreview()
                } label: {
                    Label(controller.isShortWindowOpen ? "Hide frame" : "Show frame", systemImage: "rectangle.portrait.on.rectangle.portrait")
                }
                Button {
                    controller.replayLastShort()
                } label: {
                    Label("Last take", systemImage: "play.fill")
                }
                .disabled(controller.lastShortURL == nil || controller.phase.isActive)
                .help("Play the newest short.mov")
            }

            Text(ShortFraming.describe(frame: frame))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // The frame position is not offered as a control: an editor that re-crops from
            // take.mov with its own face tracking never reads it. Where the frame sits barely
            // changes the finished Short, so use the framing guide in the preview window
            // instead. It coaches distance and phone height, which do carry through.
            Text(locked
                 ? "The frame is locked for this take, it never moves."
                 : "Open the frame (Show frame) for the eye-line and face-size guide before recording. Where you drag the frame itself barely matters any more, the editor re-crops from take.mov by tracking your face.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Screen

    private var screenSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Screen", systemImage: "display")

            Picker("Display", selection: $controller.selectedDisplayID) {
                ForEach(controller.displays, id: \.displayID) { display in
                    Text(controller.displayName(for: display))
                        .tag(Optional(display.displayID))
                }
            }

            Picker("Quality", selection: $controller.quality) {
                ForEach(RecordingController.Quality.allCases) { q in
                    Text(q.rawValue).tag(q)
                }
            }
            .pickerStyle(.segmented)

            Toggle("Microphone", isOn: $controller.captureMicrophone)
            if controller.captureMicrophone {
                microphonePicker
            }
            Toggle("System audio", isOn: $controller.captureSystemAudio)
        }
        .disabled(controller.phase.isActive || controller.phase.isBusy)
    }

    /// Quality (camera), microphone and system audio for Just me and Short.
    /// Same microphone picker as Screen mode; system audio is shown disabled
    /// because there is no screen to capture it from.
    private var cameraAudioControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            let options = controller.cameraQualityOptions
            if options.count > 1 {
                Picker("Quality", selection: $controller.cameraQuality) {
                    ForEach(options) { q in Text(q.rawValue).tag(q) }
                }
                .pickerStyle(.segmented)
                .help("Best is the camera's own top 30 fps format. Lower options pin a smaller format. Only sizes your camera really offers are listed.")
            } else {
                HStack(spacing: 4) {
                    Text("Quality:").foregroundStyle(.secondary)
                    Text("Best (the only size this camera offers)")
                }
                .font(.system(size: 12))
            }
            microphonePicker
            Toggle("System audio", isOn: .constant(false))
                .disabled(true)
            Text("System audio needs a screen to record from, so it is off in camera-only modes. Use Screen mode for it.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Shows which physical mic will actually record, and warns the moment
    /// it isn't the Mac's own, the fix for recording a whole take through
    /// AirPods or a headset by accident, with nothing on screen saying why
    /// the audio sounded worse.
    private var microphonePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            if controller.microphones.count > 1 {
                Picker("Input", selection: $controller.selectedMicrophoneID) {
                    ForEach(controller.microphones, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(Optional(device.uniqueID))
                    }
                }
            } else if let name = controller.selectedMicrophoneName {
                HStack(spacing: 4) {
                    Text("Input:").foregroundStyle(.secondary)
                    Text(name)
                }
                .font(.system(size: 12))
            }

            if controller.preferredMicMissing, let name = controller.selectedMicrophoneName,
               let preferred = RecordingController.preferredMicName {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("\(preferred) is not plugged in. Recording through \(name). "
                         + "Plug it in and it is picked automatically.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if controller.usingWorseMicrophoneThanAvailable {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Recording through \(controller.selectedMicrophoneName ?? "a different device"). "
                         + "\(controller.bestMicrophoneName ?? "Another input") is attached and is better. "
                         + "Switch Input above. Bluetooth mics drop to ~16 kHz mono when recording.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Camera

    private var cameraSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $controller.cameraEnabled) {
                sectionTitle("Camera bubble", systemImage: "person.crop.circle")
            }

            if controller.cameraEnabled {
                Picker("Camera", selection: $controller.selectedCameraID) {
                    ForEach(controller.cameras, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(Optional(device.uniqueID))
                    }
                }
                .disabled(controller.phase.isActive)

                // Studio draws the face card from the Face card setting
                // (Motion); Circle/Rounded only exist in Classic.
                if controller.screenLayout == .classic {
                    Picker("Shape", selection: $controller.bubbleShape) {
                        ForEach(BubbleShape.allCases) { shape in
                            Text(shape.rawValue).tag(shape)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                labelledSlider(
                    "Size", value: $controller.bubbleSize, range: 140...460, suffix: "px"
                )

                if controller.screenLayout == .classic, controller.bubbleShape.supportsTilt {
                    labelledSlider(
                        "Tilt", value: $controller.bubbleTilt,
                        range: -25...25, suffix: "°"
                    )
                }

                Toggle("Mirror me", isOn: $controller.mirrorCamera)

                Text(controller.screenLayout == .studio
                     ? "Studio look: the bubble is shaped and cropped exactly like the face card in the final video (\(controller.faceLayout.rawValue.lowercased()), set under Motion). Where you drag it doesn't matter. The export always puts the card in its slot. Line your eyes up with the dashed guide when it appears."
                     : "Drag the bubble anywhere. It is invisible in the raw file and painted in at the end, so it can still be moved or removed later.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Framing tips on the bubble", isOn: $controller.framingHintsOnBubble)
                    .help("A traffic light and one short tip at the bottom of the bubble. Only on your screen, never in the recording.")
            }

            checkFramingButton(
                help: controller.screenLayout == .studio
                    ? "A big live preview of every card you'll appear in (Studio\(controller.layoutMode == .dynamic && controller.studioBackground.isLight ? ", all Dynamic layouts" : "")), with guides and tips."
                    : "A big live preview of your bubble, with guides and tips."
            )
        }
    }

    /// Opens the framing window. Available before and between takes.
    private func checkFramingButton(help: String) -> some View {
        HStack(spacing: 8) {
            Button {
                controller.openFramingCheck()
            } label: {
                Label("Check framing", systemImage: "person.crop.rectangle")
            }
            .disabled(controller.phase.isActive || controller.phase.isBusy)
            Text(controller.captureMode == .screen && !controller.cameraEnabled ? "Turns the camera on." : "")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .help(help)
    }

    // MARK: - iPhone

    private var phoneSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $controller.phoneEnabled) {
                sectionTitle("iPhone screen", systemImage: "iphone")
            }

            if controller.phoneEnabled {
                if controller.phones.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(controller.phase.isActive
                             ? "Waiting for your iPhone. Plug it in and it joins this recording."
                             : "Waiting for your iPhone. Connect it with a cable, unlock it, tap Trust.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Picker("Device", selection: $controller.selectedPhoneID) {
                        ForEach(controller.phones, id: \.uniqueID) { device in
                            Text(device.localizedName).tag(Optional(device.uniqueID))
                        }
                    }
                    .disabled(controller.phase.isActive)

                    labelledSlider(
                        "Height", value: $controller.phoneHeight, range: 260...760, suffix: "px"
                    )

                    Toggle("Phone mockup frame", isOn: $controller.phoneShowsFrame)
                }

                Text("This is your phone's screen, mirrored over the cable. Your phone's camera is a different device. It shows up in the Camera list above as Continuity Camera.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Motion

    /// What the Layout setting will do for this take, in one line.
    private var layoutHelp: String {
        guard controller.layoutMode == .dynamic else {
            return "The face card stays in its slot for the whole take."
        }
        guard controller.studioBackground.isLight else {
            return "Dark room always uses the fixed layout."
        }
        return "Opens and closes on you, goes side by side or face-only while you talk with nothing happening on screen, and gives the screen more room during a long zoom. Decided at export; it never moves more than every ~7s."
    }

    private var motionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Motion", systemImage: "cursorarrow.click.2")

            HStack {
                Text("Look")
                    .font(.system(size: 12))
                Spacer()
                Picker("", selection: $controller.screenLayout) {
                    ForEach(ScreenLayout.allCases) { layout in
                        Text(layout.rawValue).tag(layout)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 170)
            }
            if controller.screenLayout == .studio {
                HStack {
                    Text("Face card")
                        .font(.system(size: 12))
                    Spacer()
                    Picker("", selection: $controller.faceLayout) {
                        ForEach(FaceLayout.allCases) { face in
                            Text(face.rawValue).tag(face)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 170)
                }
                HStack {
                    Text("Background")
                        .font(.system(size: 12))
                    Spacer()
                    Picker("", selection: $controller.studioBackground) {
                        ForEach(StudioBackground.allCases) { bg in
                            Text(bg.rawValue).tag(bg)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                }
                HStack {
                    Text("Layout")
                        .font(.system(size: 12))
                    Spacer()
                    Picker("", selection: $controller.layoutMode) {
                        ForEach(LayoutMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 170)
                }
                Text(layoutHelp)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                StudioLayoutPreview(
                    face: controller.faceLayout,
                    background: controller.studioBackground,
                    grade: controller.cameraGrade,
                    paused: controller.phase.isActive || controller.phase.isBusy,
                    cameraLive: controller.cameraEnabled,
                    frameTap: controller.cameraFrameTap
                )
                Toggle("Warm camera grade", isOn: $controller.cameraGrade)
                Toggle("Frame the focused window", isOn: $controller.frameFocusedWindow)
                Toggle("Export 4K (3840×2160)", isOn: $controller.export4K)
                    .help("Only when the capture is at least 2560 px wide; otherwise the take exports at its own size.")
            }

            HStack {
                Text("Zoom")
                    .font(.system(size: 12))
                Spacer()
                Picker("", selection: $controller.zoomMode) {
                    ForEach(ZoomMode.pickerCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 170)
            }
            if controller.zoomMode != .off {
                labelledSlider(
                    "Max zoom", value: $controller.zoomAmount,
                    range: 1.5...3.0, suffix: "×", decimals: 2
                )
                Text("\(HotKeyCenter.Shortcut.zoomHere.label) zoom here   \(HotKeyCenter.Shortcut.zoomOut.label) zoom out"
                     + (controller.zoomMode == .smart
                        ? "  ·  Smart only zooms on sustained work in one small spot or typing; your marks always win."
                        : "  ·  Only your marks zoom."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Highlight clicks", isOn: $controller.clickHighlight)
            Toggle("Our cursor (bigger, smoothed)", isOn: $controller.ownCursor)

            HStack {
                Text("Countdown")
                    .font(.system(size: 12))
                Spacer()
                Picker("", selection: $controller.countdownSeconds) {
                    Text("Off").tag(0)
                    Text("3s").tag(3)
                    Text("5s").tag(5)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 150)
            }

            Text("Clicks are saved as data, not burned in. Zoom and highlights can be retimed or removed in the edit."
                 + (controller.ownCursor
                    ? " With our cursor on, your cursor is left out of the recording and drawn back at export. On screen it stays exactly as normal."
                    : ""))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(controller.phase.isActive || controller.phase.isBusy)
    }

    // MARK: - Bluetooth button

    private var remoteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Bluetooth button")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                switch controller.remoteStatus {
                case .ready(let device):
                    Label(device.name, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                case .learning:
                    Label("Press your button…", systemImage: "dot.radiowaves.left.and.right")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                case .needsPermission:
                    Label("Needs permission", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                case .notSet:
                    Text("Not set up")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            switch controller.remoteStatus {
            case .notSet:
                Button("Learn my button") { controller.learnRemoteButton() }
            case .learning:
                Button("Cancel") { controller.cancelLearnRemoteButton() }
            case .needsPermission:
                HStack {
                    Button("Allow Input Monitoring") { RemoteButton.requestPermission() }
                    Button("I allowed it") { controller.rearmRemoteButton() }
                }
            case .ready:
                Button("Forget this button") { controller.forgetRemoteButton() }
            }
            Text("Pair the clicker to this Mac (System Settings › Bluetooth), then Learn. One press starts the take (after the countdown). While recording, one press stops it and cuts the last \(String(format: "%.1f", TailTrim.remoteStopSeconds)) s, your hand reaching for it (leave a short pause after your last word); two quick presses discard the take, like the trash button, with no question asked. Hold the button for 0.6 s while recording to move the teleprompter to the next box (needs a clicker that reports button release; the log says \"release after\" when it does). You hear Pop after a stop and Basso after a discard. Needs Input Monitoring, asked once.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(controller.phase.isActive || controller.phase.isBusy)
    }

    // MARK: - Teleprompter

    private var teleprompterSection: some View {
        TeleprompterSection(
            model: controller.teleprompter.model,
            isVisible: controller.teleprompterVisible,
            toggle: { controller.toggleTeleprompter() }
        )
    }

    // MARK: - Transport

    private var transport: some View {
        HStack(spacing: 10) {
            switch controller.phase {
            case .idle, .finished, .failed:
                Button {
                    Task { await controller.start() }
                } label: {
                    Label("Record", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)

            case .countingDown, .preparing, .finishing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busyLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

            case .recording, .paused:
                Button {
                    controller.togglePause()
                } label: {
                    Label(
                        controller.phase == .paused ? "Resume" : "Pause",
                        systemImage: controller.phase == .paused ? "play.fill" : "pause.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.large)

                Button {
                    showingDiscardConfirmation = true
                } label: {
                    Image(systemName: "trash.fill")
                        .frame(width: 20)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.large)
                .help("Discard this take, deletes it without saving")
                .confirmationDialog(
                    "Discard this take?",
                    isPresented: $showingDiscardConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Discard", role: .destructive) {
                        Task { await controller.discard() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Nothing recorded so far will be saved. This can't be undone.")
                }

                Button {
                    Task { await controller.stop() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private var busyLabel: String {
        switch controller.phase {
        case .countingDown: return "Get ready…"
        case .preparing:    return "Starting…"
        case .finishing:    return "Finishing, painting in the overlays…"
        default:            return ""
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var statusFooter: some View {
        switch controller.phase {
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Dismiss") { controller.reset() }
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .finished(let url):
            HStack {
                Label(
                    "Saved to \(controller.displayPath(for: url.deletingLastPathComponent()))",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.system(size: 11))
                .foregroundStyle(.green)
                Spacer()
                if controller.captureMode == .short {
                    Button("Play") { controller.replayLastShort() }
                        .controlSize(.small)
                }
                Button("Reveal") { controller.revealLastRecording() }
                    .controlSize(.small)
            }

        case .paused:
            Label("Paused, the finished video will have no gap",
                  systemImage: "pause.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

        default:
            HStack {
                Text("→ \(controller.destinationName)"
                     + (controller.zoomMarkCount > 0 ? "  ·  \(controller.zoomMarkCount) zoom mark(s)" : ""))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(HotKeyCenter.Shortcut.toggleRecording.label) record   \(HotKeyCenter.Shortcut.togglePause.label) pause   \(HotKeyCenter.Shortcut.zoomHere.label)/\(HotKeyCenter.Shortcut.zoomOut.label) zoom")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Screen takes finish in the background (RecordingController.finishJobs): the recorder is free
    /// again as soon as a take stops, and this list shows which takes of the video are still being
    /// painted, which are done and which failed, so you never lose your place.
    @ViewBuilder
    private var finishQueuePanel: some View {
        if !controller.finishJobs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(controller.finishJobs) { job in
                    HStack(spacing: 6) {
                        switch job.state {
                        case .working(let fraction):
                            ProgressView().controlSize(.small).scaleEffect(0.6)
                            Text("Finishing \(job.title)… \(Int(fraction * 100))%  (you can record now)")
                                .foregroundStyle(.secondary)
                        case .done:
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("\(job.title) is ready")
                        case .failed(let message):
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                            Text("\(job.title): \(message) (screen.mov is safe)").foregroundStyle(.red).lineLimit(2)
                        }
                        Spacer()
                        switch job.state {
                        case .done:
                            Button("Reveal") { controller.revealFinishJob(job) }.controlSize(.mini)
                            Button("✕") { controller.dismissFinishJob(job) }.controlSize(.mini)
                        case .failed:
                            Button("Retry") { controller.retryFinish(job) }.controlSize(.mini)
                            Button("✕") { controller.dismissFinishJob(job) }.controlSize(.mini)
                        case .working:
                            EmptyView()
                        }
                    }
                    .font(.system(size: 11))
                }
            }
        }
    }

    // MARK: - Bits

    private func sectionTitle(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 12, weight: .semibold))
    }

    private func labelledSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        suffix: String,
        decimals: Int = 0
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12))
                .frame(width: 66, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.\(decimals)f\(suffix)", value.wrappedValue))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
        }
    }
}
