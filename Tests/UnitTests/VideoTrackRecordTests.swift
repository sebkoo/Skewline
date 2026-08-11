import Testing
import Core

@Test func presentationTimeValueIsExactNanoseconds() {
    #expect(VideoTrackRecord.presentationTimeValue(of: 0) == 0)
    #expect(VideoTrackRecord.presentationTimeValue(of: 1.5) == 1_500_000_000)
    // A value the binary double cannot hold exactly still rounds to the
    // nanosecond it names.
    #expect(VideoTrackRecord.presentationTimeValue(of: 0.1) == 100_000_000)
    #expect(VideoTrackRecord.presentationTimeValue(of: 0.033333333) == 33_333_333)
}

@Test func presentationTimeValuesStayDistinctAtCaptureSpacing() {
    // A stride-2 60 Hz walk's shape: kept frames one 33.33 ms budget apart,
    // with microsecond-scale jitter thrown in. The mapping must stay
    // strictly increasing -- a collision would fold two frames onto one
    // movie sample.
    var previous = Int64.min
    for index in 0..<2000 {
        let jitter = index.isMultiple(of: 3) ? 1e-6 : 0
        let timestamp = 0.052 + Double(index) * (2.0 / 60.0) + jitter
        let value = VideoTrackRecord.presentationTimeValue(of: timestamp)
        #expect(value > previous)
        previous = value
    }
}
