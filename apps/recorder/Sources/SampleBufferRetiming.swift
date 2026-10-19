import CoreMedia

/// Rewrites a sample's timing info, subtracting a fixed offset.
///
/// Shared by every recorder that retimes samples through `RecordingClock`. /// ScreenRecorder, DeviceVideoRecorder, CameraOnlyRecorder. It used to be
/// copied into each one; pulled out once real duplication risk showed up
/// (three copies, easy for one to drift from the other two).
enum SampleBufferRetiming {

    static func retimed(_ sample: CMSampleBuffer, subtracting offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
            sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count
        ) == noErr, count > 0 else { return nil }

        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(
            sample, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count
        ) == noErr else { return nil }

        for i in 0..<count {
            if timings[i].presentationTimeStamp.isValid {
                timings[i].presentationTimeStamp =
                    CMTimeSubtract(timings[i].presentationTimeStamp, offset)
            }
            if timings[i].decodeTimeStamp.isValid {
                timings[i].decodeTimeStamp =
                    CMTimeSubtract(timings[i].decodeTimeStamp, offset)
            }
        }

        var out: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timings,
            sampleBufferOut: &out
        ) == noErr else { return nil }
        return out
    }
}
