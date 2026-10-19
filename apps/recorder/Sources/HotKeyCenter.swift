import Carbon.HIToolbox
import Foundation

/// System-wide shortcuts for start/stop and pause.
///
/// Uses Carbon's RegisterEventHotKey rather than an NSEvent global monitor
/// on purpose: a keyboard monitor would require Input Monitoring permission
/// and another scary system prompt, whereas registered hot keys need none.
///
/// The point of these is that switching to Studio Recorder to press a button
/// would put Studio Recorder in the recording.
final class HotKeyCenter {

    static let shared = HotKeyCenter()

    struct Shortcut {
        let keyCode: UInt32
        let modifiers: UInt32
        let label: String

        /// Cmd-R
        ///
        /// F6/F7 with no modifier were tried and reverted, on this
        /// keyboard the bare F-keys never reached the app (they're
        /// consumed as brightness/media keys before Carbon sees them,
        /// even with Fn held), so back to modified keys, which always work.
        ///
        /// Was Cmd-Shift-R. Dropped the Shift because it was one modifier
        /// too many to hit reliably mid-take. If Cmd-R turns out to get
        /// swallowed by whatever app is frontmost when recording (browsers
        /// and Xcode both bind Cmd-R themselves), go back to Cmd-Shift-R.
        static let toggleRecording = Shortcut(
            keyCode: UInt32(kVK_ANSI_R),
            modifiers: UInt32(cmdKey),
            label: "⌘R"
        )
        /// Cmd-P. Was Cmd-Shift-P.
        static let togglePause = Shortcut(
            keyCode: UInt32(kVK_ANSI_P),
            modifiers: UInt32(cmdKey),
            label: "⌘P"
        )
        /// "Zoom here now", on the pointer. Two modifiers on
        /// purpose: Z/X under the left hand, and ⌃⌥ combos type nothing and
        /// are bound by almost no app, so the take never loses a keystroke.
        /// Registered hot keys need no permission (see the class comment).
        static let zoomHere = Shortcut(
            keyCode: UInt32(kVK_ANSI_Z),
            modifiers: UInt32(controlKey | optionKey),
            label: "⌃⌥Z"
        )
        /// Teleprompter: previous / next box. Same ⌃⌥ family as the zoom keys.
        static let prompterBack = Shortcut(
            keyCode: UInt32(kVK_LeftArrow),
            modifiers: UInt32(controlKey | optionKey),
            label: "⌃⌥←"
        )
        static let prompterNext = Shortcut(
            keyCode: UInt32(kVK_RightArrow),
            modifiers: UInt32(controlKey | optionKey),
            label: "⌃⌥→"
        )
        /// "Zoom out / back to overview".
        static let zoomOut = Shortcut(
            keyCode: UInt32(kVK_ANSI_X),
            modifiers: UInt32(controlKey | optionKey),
            label: "⌃⌥X"
        )
    }

    private var actions: [UInt32: () -> Void] = [:]
    private var registered: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 1

    private init() {}

    func register(_ shortcut: Shortcut, action: @escaping () -> Void) {
        installHandlerIfNeeded()

        let id = nextID
        nextID += 1
        actions[id] = action

        let hotKeyID = EventHotKeyID(signature: OSType(0x5653_5444), id: id) // 'VSTD'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        _ = hotKeyID
        if status == noErr, let ref {
            registered.append(ref)
        }
    }

    func unregisterAll() {
        for ref in registered {
            UnregisterEventHotKey(ref)
        }
        registered.removeAll()
        actions.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return noErr }

                let center = Unmanaged<HotKeyCenter>
                    .fromOpaque(userData)
                    .takeUnretainedValue()

                if let action = center.actions[hotKeyID.id] {
                    DispatchQueue.main.async(execute: action)
                }
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
    }
}
