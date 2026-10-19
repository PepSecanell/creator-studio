import CoreGraphics
import Foundation

/// The shape the camera bubble is cut to.
///
/// Deliberately free of AppKit so the export path and tests
/// can both build it, the preview and the finished video must be
/// generated from the *same* path or they will disagree.
enum BubbleShape: String, CaseIterable, Identifiable {
    case circle = "Circle"
    case square = "Rounded"

    var id: String { rawValue }

    func cornerRadius(for side: CGFloat) -> CGFloat {
        switch self {
        case .circle: return side / 2
        case .square: return side * 0.22
        }
    }

    var supportsTilt: Bool { false }
}

enum BubbleShapePath {

    /// Path for a bubble filling `rect`, rotated `tiltDegrees` about its
    /// centre. Origin bottom-left, matching Core Image.
    static func path(
        for shape: BubbleShape,
        in rect: CGRect,
        tiltDegrees: CGFloat = 0
    ) -> CGPath {
        let base: CGPath
        switch shape {
        case .circle:
            base = CGPath(ellipseIn: rect, transform: nil)
        case .square:
            let radius = shape.cornerRadius(for: min(rect.width, rect.height))
            base = CGPath(
                roundedRect: rect,
                cornerWidth: radius,
                cornerHeight: radius,
                transform: nil
            )
        }

        guard tiltDegrees != 0 else { return base }

        let centre = CGPoint(x: rect.midX, y: rect.midY)
        var transform = CGAffineTransform(translationX: centre.x, y: centre.y)
            .rotated(by: tiltDegrees * .pi / 180)
            .translatedBy(x: -centre.x, y: -centre.y)
        return base.copy(using: &transform) ?? base
    }
}
