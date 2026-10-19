import AVFoundation
import CoreAudio
import CoreMediaIO
import Foundation

/// Finds cameras, and makes the iPhone show up as one.
enum DeviceDiscovery {

    /// A connected iPhone is a CoreMediaIO "screen capture" DAL device, and
    /// macOS hides that whole class of device from AVFoundation until an app
    /// explicitly opts in. This is the switch QuickTime flips to offer
    /// "iPhone" as a movie recording source. Without it the iPhone simply
    /// never appears, no matter how it is plugged in.
    ///
    /// Safe to call more than once.
    static func enableConnectedDevices() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &allow
        )
    }

    private static var deviceTypes: [AVCaptureDevice.DeviceType] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external]
        types.append(.continuityCamera)
        return types
    }

    /// Every video source we could record from, built-in camera, USB
    /// cameras, Continuity Camera, and a plugged-in iPhone.
    ///
    /// The iPhone reports itself as `.muxed` (it carries audio too), so both
    /// media types have to be swept or it goes missing.
    static func videoDevices() -> [AVCaptureDevice] {
        enableConnectedDevices()

        var found: [AVCaptureDevice] = []
        for mediaType in [AVMediaType.video, .muxed] {
            let session = AVCaptureDevice.DiscoverySession(
                deviceTypes: deviceTypes,
                mediaType: mediaType,
                position: .unspecified
            )
            for device in session.devices where !found.contains(where: { $0.uniqueID == device.uniqueID }) {
                found.append(device)
            }
        }
        return found
    }

    /// Continuity Camera is the iPhone's *camera* used as a webcam. It is a
    /// camera, and belongs in the camera list.
    static func isContinuityCamera(_ device: AVCaptureDevice) -> Bool {
        device.deviceType == .continuityCamera
    }

    /// The iPhone's *screen*, mirrored over the cable, the DAL device
    /// QuickTime records from.
    ///
    /// Both this and Continuity Camera are called "iPhone", which is exactly
    /// how they got confused: matching on the name alone put the phone's
    /// camera in the screen slot. Continuity Camera has its own device type,
    /// so rule it out first, then identify the screen by its model ID (the
    /// DAL device reports "iOS Device") or by being muxed.
    static func isPhoneScreen(_ device: AVCaptureDevice) -> Bool {
        guard !isContinuityCamera(device) else { return false }
        if device.modelID.localizedCaseInsensitiveContains("iOS Device") { return true }
        if device.hasMediaType(.muxed) { return true }
        return false
    }

    /// Everything usable as a camera, built-in, USB, and the iPhone's
    /// camera via Continuity.
    static func cameras() -> [AVCaptureDevice] {
        videoDevices().filter { !isPhoneScreen($0) }
    }

    /// Connected iPhone/iPad screens.
    static func phoneScreens() -> [AVCaptureDevice] {
        videoDevices().filter { isPhoneScreen($0) }
    }

    /// Every microphone macOS can see, the Mac's own, AirPods, a headset, a
    /// USB interface. Whichever one is plugged in and set as the system
    /// input becomes `AVCaptureDevice.default(for: .audio)`, silently, which
    /// is exactly the trap: put on Bluetooth headphones and the take
    /// records through their mic instead of the Mac's, at noticeably worse
    /// quality, with nothing on screen saying so.
    static func microphones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    /// The Mac's own microphone, built into the lid or the enclosure, never
    /// a headset or a wireless device. This is the one Studio Recorder defaults
    /// to and warns when something else is selected instead.
    static func builtInMicrophone() -> AVCaptureDevice? {
        microphones().first { $0.deviceType == .builtInMicrophone }
    }

    // MARK: - Picking the best input

    /// How good an input actually is, highest first. AVFoundation will not tell
    /// us this, every mic is `.microphone` or `.external` regardless of how it
    /// is attached, so the transport is read from CoreAudio, which is the layer
    /// that knows whether a device is on USB or on a Bluetooth voice link.
    ///
    /// The ranking is about audio, not convenience:
    ///   - **USB / Thunderbolt / FireWire (4)**, a real interface or a USB mic.
    ///     Full bandwidth, its own converter. This is where the Fifine K688CT lands.
    ///   - **Built-in (3)**, the Mac's own array. Fine, and the honest fallback.
    ///   - **Virtual / aggregate / unknown (2)**. Loopback, BlackHole, Continuity.
    ///     Works, but it is somebody else's pipeline and we cannot vouch for it.
    ///   - **Bluetooth (1)**. AirPods and headsets. The moment macOS uses one as an
    ///     INPUT it drops the whole link to the hands-free profile: mono, ~16 kHz,
    ///     heavily compressed. It sounds like a phone call and it is never the
    ///     right choice for a take.
    /// Note there is deliberately no `deviceType` check here. On macOS 14+
    /// `.builtInMicrophone` was *renamed* to `.microphone` and the two share a raw
    /// value, so `deviceType == .builtInMicrophone` is true for EVERY microphone. /// AirPods and virtual loopbacks included. Verified on a MacBook:
    /// both "BlackHole 2ch" and "MacBook Air Microphone" report
    /// `AVCaptureDeviceTypeMicrophone`. Transport is the only thing that still
    /// tells them apart.
    static func microphoneRank(_ device: AVCaptureDevice) -> Int {
        switch transportType(uniqueID: device.uniqueID) {
        case kAudioDeviceTransportTypeUSB,
             kAudioDeviceTransportTypeThunderbolt,
             kAudioDeviceTransportTypeFireWire,
             kAudioDeviceTransportTypePCI:
            return 4
        case kAudioDeviceTransportTypeBuiltIn:
            return 3
        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE:
            return 1
        case kAudioDeviceTransportTypeVirtual,
             kAudioDeviceTransportTypeAggregate:
            // BlackHole, Loopback, aggregates. These are routing plumbing, and a
            // loopback has no live input at all, picking one silently records
            // nothing. Below the built-in, always.
            return 2
        default:
            return 2
        }
    }

    /// The best input currently attached. Ties break toward the Mac's own mic,
    /// because a tie means we could not tell them apart and the built-in is the
    /// one we can reason about.
    static func bestMicrophone() -> AVCaptureDevice? {
        let mics = microphones()
        guard !mics.isEmpty else { return nil }
        let best = mics.map(microphoneRank).max() ?? 0
        let tied = mics.filter { microphoneRank($0) == best }
        return tied.first {
            transportType(uniqueID: $0.uniqueID) == kAudioDeviceTransportTypeBuiltIn
        } ?? tied.first
    }

    /// CoreAudio's transport type for the device with this AVFoundation uniqueID.
    /// AVFoundation and CoreAudio share the UID string, which is what makes the
    /// lookup possible at all. Returns 0 when the device cannot be found.
    static func transportType(uniqueID: String) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
            size > 0 else { return 0 }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return 0 }

        for id in ids {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var uidSize = UInt32(MemoryLayout<CFString?>.size)
            var uid: CFString? = nil
            guard AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &uidSize, &uid) == noErr,
                  (uid as String?) == uniqueID else { continue }

            var transportAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(
                id, &transportAddress, 0, nil, &transportSize, &transport) == noErr
            else { return 0 }
            return transport
        }
        return 0
    }
}
