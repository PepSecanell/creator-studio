import Foundation
import IOKit.hid

/// A Bluetooth selfie button (the little clicker that takes a photo or
/// starts and ends a video on a phone) used as a start/stop button for the
/// Mac.
///
/// Why this exists: you may record from far away, so ⌘R means walking to the
/// keyboard, and the walk and the keypress end up in the take.
///
/// How these buttons work: they pair as a tiny keyboard and send one key
/// (usually Volume Up, sometimes Enter). The Carbon hot keys in
/// `HotKeyCenter` cannot see that, because Volume Up is a media key, so this
/// reads the HID device itself (`IOHIDManager`). That needs the **Input
/// Monitoring** permission, asked once, only when the button is set up.
///
/// **Learning, not guessing.** Different clickers send different keys, so
/// the app never hard-codes one. "Learn my button" waits for the first press
/// from a non-Apple Bluetooth device and remembers that device
/// (vendor + product). From then on, *any* press on *that* device toggles
/// the recording, and nothing from the Mac's own keyboard ever does.
///
/// **The press is swallowed.** Once learned, the device is opened exclusively
/// (`kIOHIDOptionsTypeSeizeDevice`) so macOS never sees the Volume Up and the
/// Mac's volume does not move on every take. If the exclusive open is refused
/// it falls back to listening, and the volume bumps are the only side effect.
final class RemoteButton {

    static let shared = RemoteButton()

    struct Device: Equatable {
        let vendorID: Int
        let productID: Int
        let name: String
    }

    enum Status: Equatable {
        /// No button learned yet.
        case notSet
        /// Waiting for the first press.
        case learning
        /// Learned and listening.
        case ready(Device)
        /// Learned, but the Input Monitoring grant is missing.
        case needsPermission
    }

    /// Called on the main thread on every accepted press.
    var onPress: (() -> Void)?
    /// Called on the main thread when the button is HELD (>= 0.6 s) and the clicker reports
    /// releases, so a hold can be told from a tap. The tap itself has already been delivered
    /// through `onPress`; the controller cancels what that tap started.
    var onLongPress: (() -> Void)?
    /// Called on the main thread whenever `status` changes.
    var onStatusChange: ((Status) -> Void)?

    private(set) var status: Status = .notSet {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }

    private static let vendorKey = "remoteButtonVendorID"
    private static let productKey = "remoteButtonProductID"
    private static let nameKey = "remoteButtonName"
    /// A press within this window of the last one is the same press (some
    /// clickers send down+up). Short on purpose: a deliberate double press
    /// (discard) is usually 0.2 s or more apart.
    private static let debounce: TimeInterval = 0.15
    private static let appleVendorID = 0x05AC

    private var manager: IOHIDManager?
    private var lastPress = Date.distantPast
    private var isLearning = false
    private var hold = HoldDetector()
    private var holdTimer: DispatchWorkItem?

    private init() {}

    // MARK: - Stored device

    var learned: Device? {
        let d = UserDefaults.standard
        guard d.object(forKey: Self.vendorKey) != nil else { return nil }
        // A Mac-internal device must never be the button: it would be seized, and every
        // key on the laptop would start or stop a take .
        let vendor = d.integer(forKey: Self.vendorKey)
        if vendor == 0 || vendor == Self.appleVendorID || (d.string(forKey: Self.nameKey) ?? "").contains("Apple") {
            Diagnostics.log("remote button: stored device is a Mac keyboard, forgetting it")
            d.removeObject(forKey: Self.vendorKey)
            d.removeObject(forKey: Self.productKey)
            d.removeObject(forKey: Self.nameKey)
            return nil
        }
        return Device(
            vendorID: d.integer(forKey: Self.vendorKey),
            productID: d.integer(forKey: Self.productKey),
            name: d.string(forKey: Self.nameKey) ?? "Bluetooth button"
        )
    }

    private func store(_ device: Device) {
        let d = UserDefaults.standard
        d.set(device.vendorID, forKey: Self.vendorKey)
        d.set(device.productID, forKey: Self.productKey)
        d.set(device.name, forKey: Self.nameKey)
    }

    func forget() {
        stopManager()
        isLearning = false
        let d = UserDefaults.standard
        d.removeObject(forKey: Self.vendorKey)
        d.removeObject(forKey: Self.productKey)
        d.removeObject(forKey: Self.nameKey)
        status = .notSet
        Diagnostics.log("remote button forgotten")
    }

    // MARK: - Permission

    static var hasPermission: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Prompts the first time; afterwards macOS stays silent, so also open
    /// the settings pane.
    static func requestPermission() {
        if !IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) {
            Permissions.openSettings(pane: "Privacy_ListenEvent")
        }
    }

    // MARK: - Lifecycle

    /// Starts listening for the learned button, if there is one. Safe to call
    /// repeatedly (launch, after granting permission).
    func arm() {
        guard !isLearning else { return }
        stopManager()
        guard let device = learned else {
            status = .notSet
            return
        }
        guard Self.hasPermission else {
            status = .needsPermission
            return
        }
        start(matching: [
            kIOHIDVendorIDKey: device.vendorID,
            kIOHIDProductIDKey: device.productID
        ], seize: true)
        status = .ready(device)
        Diagnostics.log("remote button armed: \(device.name) (\(device.vendorID):\(device.productID))")
    }

    /// Waits for the first press from a non-Apple device and learns it.
    func startLearning() {
        guard Self.hasPermission else {
            Self.requestPermission()
            status = .needsPermission
            return
        }
        stopManager()
        isLearning = true
        status = .learning
        // Keyboards and consumer-control (media key) devices only; the
        // press filter below drops Apple's own.
        start(matching: nil, seize: false)
        Diagnostics.log("remote button: learning")
    }

    func cancelLearning() {
        guard isLearning else { return }
        isLearning = false
        arm()
    }

    // MARK: - IOHIDManager

    private func start(matching: [String: Int]?, seize: Bool) {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        if let matching {
            IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        } else {
            let pairs: [[String: Int]] = [
                [kIOHIDDeviceUsagePageKey: 0x01, kIOHIDDeviceUsageKey: 0x06], // keyboard
                [kIOHIDDeviceUsagePageKey: 0x0C, kIOHIDDeviceUsageKey: 0x01], // consumer control
            ]
            IOHIDManagerSetDeviceMatchingMultiple(manager, pairs as CFArray)
        }
        armedAt = Date()
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, sender, value in
            guard let context else { return }
            let me = Unmanaged<RemoteButton>.fromOpaque(context).takeUnretainedValue()
            me.handle(value: value, sender: sender)
        }, context)
        // These clickers sleep and drop off Bluetooth when idle. Log it, and when the button comes
        // back re-open it so the exclusive grab and the callback are fresh (a press that only
        // woke the clicker is lost; that part no software can recover).
        if !isLearning {
            IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
                guard let context else { return }
                let me = Unmanaged<RemoteButton>.fromOpaque(context).takeUnretainedValue()
                me.deviceAppeared(name: RemoteButton.stringProperty(device, kIOHIDProductKey) ?? "?")
            }, context)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, { _, _, _, device in
                Diagnostics.log("remote button: disconnected (\(RemoteButton.stringProperty(device, kIOHIDProductKey) ?? "?"))")
            }, context)
        }
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        var result = IOHIDManagerOpen(manager, IOOptionBits(seize ? kIOHIDOptionsTypeSeizeDevice : kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess, seize {
            Diagnostics.log("remote button: exclusive open refused (\(result)); listening without it")
            result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if result != kIOReturnSuccess {
            Diagnostics.log("remote button: could not open HID manager (\(result))")
        }
        self.manager = manager
    }

    private var armedAt = Date.distantPast

    /// The matching callback also fires for every device already present when the manager opens
    /// (a clicker can expose several HID interfaces); only a LATER one is a reconnect worth
    /// re-arming for. The 3 s window also stops a re-arm from triggering itself.
    private func deviceAppeared(name: String) {
        guard !isLearning, Date().timeIntervalSince(armedAt) > 3 else { return }
        Diagnostics.log("remote button: reconnected (\(name)), re-arming")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.arm() }
    }

    /// Re-open after the Mac wakes: the clicker's link is rebuilt on wake and a manager opened
    /// before sleep can end up holding a dead handle.
    func rearmAfterWake() {
        guard status != .notSet, !isLearning else { return }
        Diagnostics.log("remote button: Mac woke, re-arming")
        arm()
    }

    private func stopManager() {
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
    }

    // MARK: - Events

    private func handle(value: IOHIDValue, sender: UnsafeMutableRawPointer?) {
        // Keys report 1 (or a key code) down, 0 up. A release only matters for hold detection.
        let isDown = IOHIDValueGetIntegerValue(value) != 0
        let element = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(element)
        if isLearning, isDown {
            let dev = IOHIDElementGetDevice(element)
            Diagnostics.log("remote button: heard page \(page) from \(Self.stringProperty(dev, kIOHIDProductKey) ?? "?") (\(Self.intProperty(dev, kIOHIDVendorIDKey)))")
        }
        // 0x09 = Button page: some shutter clickers use it instead of keys.
        guard page == 0x07 || page == 0x0C || page == 0x09 else { return }
        guard isDown else {
            guard !isLearning else { return }
            let held = hold.release(at: Date.timeIntervalSinceReferenceDate)
            holdTimer?.cancel(); holdTimer = nil
            if let held { Diagnostics.log(String(format: "remote button release after %.2f s", held)) }
            return
        }

        let device = IOHIDElementGetDevice(element)
        let vendor = Self.intProperty(device, kIOHIDVendorIDKey)
        let product = Self.intProperty(device, kIOHIDProductIDKey)
        let name = Self.stringProperty(device, kIOHIDProductKey) ?? "Bluetooth button"

        if isLearning {
            // Never learn the Mac's own keyboard/trackpad or an Apple Magic Keyboard. The
            // built-in one reports vendor 0 (not Apple's), which slipped past the old check.
            let transport = (Self.stringProperty(device, kIOHIDTransportKey) ?? "").lowercased()
            let builtIn = ["spi", "fifo", "i2c", "internal"].contains { transport.contains($0) }
            guard vendor != Self.appleVendorID, vendor != 0, !builtIn,
                  !name.contains("Apple") else { return }
            let learnedDevice = Device(vendorID: vendor, productID: product, name: name)
            store(learnedDevice)
            isLearning = false
            Diagnostics.log("remote button learned: \(name) (\(vendor):\(product)) page \(page)")
            // The manager that heard this is listening to everything and is
            // not exclusive; swap it for the exclusive, device-only one.
            DispatchQueue.main.async { [weak self] in self?.arm() }
            return
        }

        let now = Date()
        guard now.timeIntervalSince(lastPress) > Self.debounce else { return }
        lastPress = now
        Diagnostics.log("remote button press")
        onPress?()
        // Long press = next teleprompter box. Only when this clicker has shown it reports releases.
        hold.press(at: Date.timeIntervalSinceReferenceDate)
        holdTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.hold.isHeld(at: Date.timeIntervalSinceReferenceDate) else { return }
            Diagnostics.log("remote button long press")
            self.onLongPress?()
        }
        holdTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + HoldDetector.holdSeconds, execute: item)
    }

    private static func intProperty(_ device: IOHIDDevice, _ key: String) -> Int {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0
    }

    private static func stringProperty(_ device: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }
}
