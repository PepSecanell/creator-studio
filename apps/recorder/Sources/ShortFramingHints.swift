import SwiftUI

// Short mode's own voice for the framing guide. The generic
// FramingRules.message() wording ("tilt the camera up") was written for the
// Just me / Screen "Check framing" window, where the camera is a MacBook or a
// mounted iPhone the same distance every time. Short is filmed handheld or
// propped low, close to the face, so the same measurements get plainer,
// phone-specific lines, tuned to sample takes (eyes measured at
// 0.44-0.45 of the frame vs the 0.40 target, face 0.21-0.26 vs 0.30) and to
// the editor's own constants (eyes at 0.40, face height 580 of 1920 ≈ 0.302).
//
// FramingCoach.step(message:) is what makes this possible without touching
// the shared engine: it takes a formatter closure, defaulting to
// FramingRules.message everywhere else. Short is the only caller that passes
// this one in.
enum ShortFramingHints {

    static let good = "Framing looks good"

    /// Same signature as `FramingRules.message` (kind, major, mirrored,
    /// place) so it drops straight into `FramingCoach.step(message:)`.
    /// `place` is unused: Short only ever has one crop, so it is always nil.
    static func message(_ kind: FramingIssueKind, _ major: Bool, _ mirrored: Bool, _ place: String?) -> String {
        switch kind {
        case .noFace:
            return "Can't see your face, sit in front of the phone"
        case .headCut:
            return "The top of your head is cut off, move down a little in the frame"
        case .chinCut:
            return "Your chin is cut off, sit back a little"
        case .outOfCrop:
            // FramingCoach always rewrites .outOfCrop into tooClose/offLeft/
            // offRight before it reaches a message() call; kept for
            // exhaustiveness only.
            return "You're running out of the frame"
        case .tooClose:
            return major ? "Too close. Sit back, or turn the iPhone upright for a wider shot" : "Sit back a little (or turn the iPhone upright)"
        case .tooFar:
            return major ? "Sit closer, you're too far from the phone" : "Sit a little closer"
        // Eyes low in the picture = the phone is aiming up at the chin
        // (mounted below eye level, on sample takes). Raising the
        // phone toward eye height is the direct fix, not an abstract tilt.
        case .eyesLow:
            return major ? "Raise the phone to eye level" : "Raise the phone a little"
        case .eyesHigh:
            return major ? "Lower the phone to eye level" : "Lower the phone a little"
        case .offLeft, .offRight:
            let pictureRight = (kind == .offLeft)
            let yourRight = mirrored ? pictureRight : !pictureRight
            return (major ? "Move to your " : "Move a little to your ") + (yourRight ? "right" : "left")
        case .tilted:
            return "Straighten the phone"
        case .tooDark:
            return "Too dark, add a light in front of you"
        case .backlit:
            return "Too much light behind you, face the window or lamp"
        case .washedOut:
            return "Too bright on your face, soften the light"
        }
    }
}

// MARK: - Brand-safe status colour

/// Short mode's guide draws directly over the vertical frame, next to the
/// rest of its cream/chocolate/dusty-rose chrome, so it stays off
/// the red/orange/green traffic light the separate "Check framing" window
/// uses, that one stays exactly as it was.
extension FramingStatus {
    var shortColor: Color {
        switch self {
        case .good:    return Color(red: 0.961, green: 0.929, blue: 0.847)   // cream
        case .adjust:  return Color(red: 0.831, green: 0.643, blue: 0.604)   // dusty rose
        case .fix:     return Color(red: 0.47, green: 0.24, blue: 0.12)      // chocolate, lifted enough to read on a dark stage
        case .unknown: return Color(red: 0.961, green: 0.929, blue: 0.847).opacity(0.4)
        }
    }
}
