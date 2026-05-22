import CoreGraphics
import CoreMedia
import Testing

@testable import Iris

// MARK: - Helpers

private func makeDetection(label: String, x: Double = 0.0) -> Detection {
    Detection(
        boundingBox: CGRect(x: x, y: 0.1, width: 0.2, height: 0.2),
        label: label,
        confidence: 1.0,
        sourceModelID: "result-store-tests"
    )
}

private func timestamped(
    _ value: Int64,
    timescale: Int32 = 60,
    label: String = "x"
) -> TimestampedDetections {
    TimestampedDetections(
        timestamp: CMTime(value: CMTimeValue(value), timescale: timescale),
        detections: [makeDetection(label: label)]
    )
}

// MARK: - Tests

@MainActor
@Suite("ResultStore")
struct ResultStoreTests {

    @Test
    func appendInsertsInTimestampOrderRegardlessOfArrival() {
        let store = ResultStore()
        store.append(timestamped(30, label: "c"))
        store.append(timestamped(10, label: "a"))
        store.append(timestamped(20, label: "b"))

        // After three out-of-order appends, the most-recent result for any
        // displayTime >= 30/60 should be the t=30 entry — confirming order.
        let now = CMTime(value: 30, timescale: 60)
        let dets = store.lookup(at: now, stale: CMTime(value: 1, timescale: 1))
        #expect(dets.first?.label == "c")

        // And the t<=20 lookup picks the t=20 entry, not t=30.
        let earlier = CMTime(value: 20, timescale: 60)
        let earlierDets = store.lookup(at: earlier, stale: CMTime(value: 1, timescale: 1))
        #expect(earlierDets.first?.label == "b")

        // And the t<=10 lookup picks the t=10 entry.
        let earliest = CMTime(value: 10, timescale: 60)
        let earliestDets = store.lookup(at: earliest, stale: CMTime(value: 1, timescale: 1))
        #expect(earliestDets.first?.label == "a")
    }

    @Test
    func appendEvictsOldestWhenOverCapacity() {
        let store = ResultStore(capacity: 3)
        store.append(timestamped(10, label: "a"))
        store.append(timestamped(20, label: "b"))
        store.append(timestamped(30, label: "c"))
        store.append(timestamped(40, label: "d"))

        // The t=10 entry should be evicted. Looking up at t=10 should now
        // return [] (no entry with timestamp <= 10 survives) — generous
        // stale threshold so staleness isn't what's filtering.
        let stale = CMTime(value: 100, timescale: 1)
        let dets = store.lookup(at: CMTime(value: 10, timescale: 60), stale: stale)
        #expect(dets.isEmpty)

        // The t=20 entry should still be there.
        let later = store.lookup(at: CMTime(value: 20, timescale: 60), stale: stale)
        #expect(later.first?.label == "b")
    }

    @Test
    func lookupReturnsMostRecentResultAtOrBeforeDisplayTime() {
        let store = ResultStore()
        store.append(timestamped(10, label: "a"))
        store.append(timestamped(20, label: "b"))
        store.append(timestamped(30, label: "c"))

        // displayTime = 25 (between t=20 and t=30) should return t=20.
        let mid = CMTime(value: 25, timescale: 60)
        let stale = CMTime(value: 1, timescale: 1)
        let dets = store.lookup(at: mid, stale: stale)
        #expect(dets.first?.label == "b")

        // Exact match on a buffered timestamp returns that entry.
        let exact = store.lookup(at: CMTime(value: 30, timescale: 60), stale: stale)
        #expect(exact.first?.label == "c")
    }

    @Test
    func lookupReturnsEmptyWhenBufferEmpty() {
        let store = ResultStore()
        let dets = store.lookup(at: CMTime(value: 5, timescale: 60))
        #expect(dets.isEmpty)
    }

    @Test
    func lookupReturnsEmptyWhenDisplayTimeBeforeAnyResult() {
        let store = ResultStore()
        store.append(timestamped(20, label: "a"))
        store.append(timestamped(30, label: "b"))

        let early = CMTime(value: 10, timescale: 60)
        let dets = store.lookup(at: early, stale: CMTime(value: 1, timescale: 1))
        #expect(dets.isEmpty)
    }

    @Test
    func lookupReturnsEmptyWhenNewestResultIsStaleBeyondThreshold() {
        let store = ResultStore()
        // Newest entry is at t=1.0s; displayTime is at t=2.0s; stale threshold
        // is 100 ms. 1.0s gap > 100ms, so lookup must return [].
        let entry = TimestampedDetections(
            timestamp: CMTime(value: 1, timescale: 1),
            detections: [makeDetection(label: "stale")]
        )
        store.append(entry)
        let now = CMTime(value: 2, timescale: 1)
        let stale = CMTime(value: 100, timescale: 1000)
        let dets = store.lookup(at: now, stale: stale)
        #expect(dets.isEmpty)

        // Sanity: with a generous threshold the same lookup yields the entry.
        let lenient = CMTime(value: 10, timescale: 1)
        let dets2 = store.lookup(at: now, stale: lenient)
        #expect(dets2.first?.label == "stale")
    }

    @Test
    func clearEmptiesTheBuffer() {
        let store = ResultStore()
        store.append(timestamped(10, label: "a"))
        store.append(timestamped(20, label: "b"))
        store.clear()

        let dets = store.lookup(
            at: CMTime(value: 20, timescale: 60),
            stale: CMTime(value: 1, timescale: 1)
        )
        #expect(dets.isEmpty)
    }

    @Test
    func defaultStalenessThresholdIsFiveHundredMilliseconds() {
        let store = ResultStore()
        // Default liveStalenessThreshold is 500 ms; an entry at t=0 looked up
        // at t=600ms must be suppressed by default.
        let entry = TimestampedDetections(
            timestamp: CMTime(value: 0, timescale: 1000),
            detections: [makeDetection(label: "live")]
        )
        store.append(entry)
        let withinDefault = store.lookup(at: CMTime(value: 400, timescale: 1000))
        #expect(withinDefault.first?.label == "live")

        let beyondDefault = store.lookup(at: CMTime(value: 600, timescale: 1000))
        #expect(beyondDefault.isEmpty)
    }
}
