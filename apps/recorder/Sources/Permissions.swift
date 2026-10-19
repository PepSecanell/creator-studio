import AVFoundation
import AppKit
import CoreGraphics
import Foundation

/// Every TCC permission the app needs, in one place.
///
/// Learned the hard way: replacing the app bundle in /Applications resets
/// these, and a missing microphone grant used to surface as a cryptic
/// "could not write the recording" only after a take had already been
/// attempted, leaving a corrupt file behind. Now they are checked up
/// front, named individually, and each one can be requested from the UI.
enum Permissions {

    enum State {
        case granted
        case denied
        case notAsked

        var isUsable: Bool { self == .granted }
    }

    // MARK: - Screen

    static var screen: State {
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    /// Only prompts once per app install; afterwards macOS silently refuses,
    /// so fall through to opening the settings pane.
    static func requestScreen() {
        if !CGRequestScreenCaptureAccess() {
            openSettings(pane: "Privacy_ScreenCapture")
        }
    }

    // MARK: - Microphone

    static var microphone: State {
        state(for: AVCaptureDevice.authorizationStatus(for: .audio))
    }

    @discardableResult
    static func requestMicrophone() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            openSettings(pane: "Privacy_Microphone")
            return false
        }
    }

    // MARK: - Camera

    static var camera: State {
        state(for: AVCaptureDevice.authorizationStatus(for: .video))
    }

    @discardableResult
    static func requestCamera() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            openSettings(pane: "Privacy_Camera")
            return false
        }
    }

    // MARK: - Bits

    private static func state(for status: AVAuthorizationStatus) -> State {
        switch status {
        case .authorized:    return .granted
        case .notDetermined: return .notAsked
        default:             return .denied
        }
    }

    static func openSettings(pane: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
