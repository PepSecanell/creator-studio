import Foundation

/// A stretch of the take during which one overlay device was actually
/// delivering frames, in seconds on the recording clock.
///
/// An overlay is not simply "on for the whole take". The iPhone can be
/// plugged in ten minutes in, unplugged, and plugged back again, each
/// connection is its own segment, with nothing in between.
///
/// This exists because AVFoundation will not tell us. Ask a composition
/// track for a frame past the end of its media and it hands back the **last
/// frame it had**, forever, rather than nothing, so an unplugged iPhone
/// freezes on screen instead of disappearing. The recorder therefore notes
/// when frames really arrived, and the compositor draws only then.
struct ClipSegment: Equatable {
    var start: Double
    var end: Double

    var isEmpty: Bool { end <= start }
}

extension Array where Element == ClipSegment {

    /// Opacity for an overlay at `time`: solid while a segment is running,
    /// fading in as it joins and out as it drops.
    ///
    /// An empty array means "no information", the overlay stays visible,
    /// which keeps older takes and the camera-only path behaving as before.
    func overlayAlpha(at time: Double, fade: Double) -> CGFloat {
        guard !isEmpty else { return 1 }

        for segment in self {
            if time >= segment.start, time <= segment.end {
                // No fade-in at the very top of the take: the overlay was
                // already there, it did not arrive.
                guard segment.start > fade else { return 1 }
                let since = time - segment.start
                return since < fade ? CGFloat(since / fade) : 1
            }
            if time > segment.end, time - segment.end < fade {
                return CGFloat(1 - (time - segment.end) / fade)
            }
        }
        return 0
    }
}
