import CoreGraphics
import CoreMedia
import Testing

@testable import Iris

// Storage shape changed in `plans/features/playback-detection-cache.md`
// Phase 1: `ResultStore` is now a persistent timestamp-keyed cache, not a
// fixed-size ring. The pre-Phase-1 tests `appendInsertsInTimestampOrder…`
// (ordered iteration), `appendEvictsOldestWhenOverCapacity` (capacity
// eviction), `lookupReturnsEmptyWhenDisplayTimeBeforeAnyResult` (strict
// `<= displayTime` lookup), and `defaultStalenessThresholdIsFiveHundred…`
// (lookup-far-past with no window cap) were removed because they encoded
// behaviors that no longer hold: nearest-neighbor lookup is symmetric, the
// adaptive `2 × quantization` window suppresses far-past hits even with a
// generous `stale:` cap, and there is no capacity bound.

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
    seconds: Double,
    label: String = "x"
) -> TimestampedDetections {
    TimestampedDetections(
        timestamp: CMTime(seconds: seconds, preferredTimescale: 600),
        detections: [makeDetection(label: label)]
    )
}

private let generousStale = CMTime(value: 10, timescale: 1)

// MARK: - Tests

@MainActor
@Suite("ResultStore")
struct ResultStoreTests {

    // 1. Quantization bucketing — 1.012s and 0.998s both land in the same
    //    30fps bucket as 1.000s; the later write wins.
    @Test
    func quantizationBucketsNearbyTimestampsTogether() {
        let store = ResultStore()  // default 1/30s quantization
        store.append(timestamped(seconds: 1.012, label: "first"))
        store.append(timestamped(seconds: 0.998, label: "second"))  // same bucket, overwrites

        let dets = store.lookup(
            at: CMTime(seconds: 1.000, preferredTimescale: 600),
            stale: generousStale
        )
        #expect(dets.first?.label == "second")
    }

    // 2. Nearest-neighbor lookup within window; outside window → [].
    @Test
    func nearestNeighborLookupWithinWindowAndEmptyOutside() {
        let store = ResultStore()
        store.append(timestamped(seconds: 1.000, label: "a"))

        // 1.005s is within the 2/30 ≈ 66.7ms adaptive window of bucket 1.000s.
        let nearHit = store.lookup(
            at: CMTime(seconds: 1.005, preferredTimescale: 600),
            stale: generousStale
        )
        #expect(nearHit.first?.label == "a")

        // 1.500s is well outside the adaptive window.
        let farMiss = store.lookup(
            at: CMTime(seconds: 1.500, preferredTimescale: 600),
            stale: generousStale
        )
        #expect(farMiss.isEmpty)
    }

    // 3. Idempotent insert at the same bucket — second write wins.
    @Test
    func idempotentInsertAtSameBucketLastWriteWins() {
        let store = ResultStore()
        store.append(timestamped(seconds: 1.000, label: "first"))
        store.append(timestamped(seconds: 1.000, label: "second"))

        let dets = store.lookup(
            at: CMTime(seconds: 1.000, preferredTimescale: 600),
            stale: generousStale
        )
        #expect(dets.count == 1)
        #expect(dets.first?.label == "second")
    }

    // 4. `contains(timestamp:)` — bucket-aware membership probe.
    @Test
    func containsIsBucketAwareAndCheap() {
        let store = ResultStore()
        store.append(timestamped(seconds: 1.012, label: "a"))

        // Inserted at 1.012s, which buckets to ~1.000s at 30fps.
        #expect(store.contains(timestamp: CMTime(seconds: 1.012, preferredTimescale: 600)))
        // 0.998s buckets to the same place.
        #expect(store.contains(timestamp: CMTime(seconds: 0.998, preferredTimescale: 600)))
        // Empty bucket far away.
        #expect(!store.contains(timestamp: CMTime(seconds: 5.000, preferredTimescale: 600)))
    }

    // 5. `clear()` empties the cache.
    @Test
    func clearEmptiesTheCache() {
        let store = ResultStore()
        store.append(timestamped(seconds: 1.0, label: "a"))
        store.append(timestamped(seconds: 2.0, label: "b"))
        store.clear()

        let dets = store.lookup(
            at: CMTime(seconds: 1.0, preferredTimescale: 600),
            stale: generousStale
        )
        #expect(dets.isEmpty)
        #expect(!store.contains(timestamp: CMTime(seconds: 1.0, preferredTimescale: 600)))
        #expect(!store.contains(timestamp: CMTime(seconds: 2.0, preferredTimescale: 600)))
    }

    // 6. Stale hard-cap — when `stale:` is tighter than the adaptive
    //    window, lookup uses the tighter cap.
    @Test
    func staleParameterIsHardCapTighterThanAdaptiveWindow() {
        let store = ResultStore()
        store.append(timestamped(seconds: 1.000, label: "a"))

        // Adaptive window is 2/30 ≈ 66.7ms. Looking up at 1.030s with a
        // 10ms hard cap should miss (gap ≈ 30ms > 10ms), even though it
        // would hit under the adaptive window alone.
        let tight = CMTime(value: 10, timescale: 1000)  // 10ms
        let miss = store.lookup(
            at: CMTime(seconds: 1.030, preferredTimescale: 600),
            stale: tight
        )
        #expect(miss.isEmpty)

        // Sanity: a generous cap finds it.
        let hit = store.lookup(
            at: CMTime(seconds: 1.030, preferredTimescale: 600),
            stale: generousStale
        )
        #expect(hit.first?.label == "a")
    }

    // 7. Non-monotonic insert — t=2.0 then t=1.0 both succeed; no
    //    ring-buffer ordering assumption.
    @Test
    func nonMonotonicInsertsBothSucceed() {
        let store = ResultStore()
        store.append(timestamped(seconds: 2.0, label: "later"))
        store.append(timestamped(seconds: 1.0, label: "earlier"))

        let later = store.lookup(
            at: CMTime(seconds: 2.0, preferredTimescale: 600),
            stale: generousStale
        )
        #expect(later.first?.label == "later")

        let earlier = store.lookup(
            at: CMTime(seconds: 1.0, preferredTimescale: 600),
            stale: generousStale
        )
        #expect(earlier.first?.label == "earlier")
    }

    // Sanity: `lookup` on an empty store returns [] without crashing.
    @Test
    func lookupReturnsEmptyWhenStoreIsEmpty() {
        let store = ResultStore()
        let dets = store.lookup(at: CMTime(seconds: 1.0, preferredTimescale: 600))
        #expect(dets.isEmpty)
    }
}
