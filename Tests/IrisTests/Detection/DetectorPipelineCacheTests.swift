import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import Testing

@testable import Iris

// MARK: - Helpers

/// IOSurface-backed synthetic frame, mirrors `DetectorTests`' helper.
/// Re-declared here so the cache tests stand alone (different timestamp
/// matrix per test) without coupling to the un-related fixture file.
private func makeSyntheticFrame(
    timestamp: CMTime,
    width: Int = 64,
    height: Int = 48
) -> Frame {
    let attrs: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
    ]
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        attrs as CFDictionary,
        &buffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer = buffer else {
        fatalError("CVPixelBufferCreate failed with status \(status)")
    }
    return Frame(
        pixelBuffer: pixelBuffer,
        timestamp: timestamp,
        orientation: .up,
        source: .mock("detector-pipeline-cache-tests"),
        format: .yuv420BiPlanarFull,
        dimensions: CGSize(width: width, height: height)
    )
}

/// Thread-safe call counter. Detector conformers must be `Sendable`; this
/// actor lets the `RecordingDetector` `struct` share a mutable count
/// across actor hops without `@unchecked`.
private actor CallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

/// `Detector` test double that increments a shared `CallCounter` each
/// time `detect(in:)` is invoked and returns a configured detection list.
/// Pipeline cache-skip behavior is observed via the counter.
private struct RecordingDetector: Detector {
    let availability: DetectorAvailability = .available
    let modelIdentifier: String
    let counter: CallCounter
    let detections: [Detection]

    init(
        identifier: String = "recording",
        counter: CallCounter,
        detections: [Detection] = []
    ) {
        self.modelIdentifier = identifier
        self.counter = counter
        self.detections = detections
    }

    func prewarm() async {}

    func detect(in frame: Frame) async throws -> [Detection] {
        await counter.increment()
        return detections
    }
}

private func makeDetection(label: String = "rect") -> Detection {
    Detection(
        boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
        label: label,
        confidence: 0.9,
        sourceModelID: "recording"
    )
}

// MARK: - Tests

/// Cache miss runs the detector and writes through to the cache so the
/// next visit at the same bucket can short-circuit.
@Test
@MainActor
func cacheMissRunsDetectorAndWritesThrough() async throws {
    let counter = CallCounter()
    let detector = RecordingDetector(counter: counter, detections: [makeDetection()])
    let pipeline = DetectorPipeline(detector)
    let cache = ResultStore()
    let timestamp = CMTime(value: 1000, timescale: 1000)  // 1.000s
    let frame = makeSyntheticFrame(timestamp: timestamp)

    let result = try await pipeline.detect(in: frame, cache: cache)

    #expect(await counter.count == 1)
    #expect(result.count == 1)
    #expect(cache.contains(timestamp: timestamp))
}

/// On cache hit: detector dispatch is skipped *and* the cached
/// detections are returned (not `[]`). Pre-seed the cache with a known
/// `TimestampedDetections` at t=1.000s, then call `detect(in:cache:)` at
/// the same timestamp and assert both behaviors — no detector run, and
/// the returned `[Detection]` equals the seeded detections.
@Test
@MainActor
func cacheHitSkipsDetectorAndReturnsCachedDetections() async throws {
    let counter = CallCounter()
    let detector = RecordingDetector(counter: counter, detections: [makeDetection()])
    let pipeline = DetectorPipeline(detector)
    let cache = ResultStore()
    let timestamp = CMTime(value: 1000, timescale: 1000)  // 1.000s
    let frame = makeSyntheticFrame(timestamp: timestamp)

    // Pre-seed with a sentinel detection that cannot have come from the
    // recording detector — distinct label makes the source unambiguous.
    let sentinel = makeDetection(label: "cached-sentinel")
    cache.append(TimestampedDetections(timestamp: timestamp, detections: [sentinel]))

    let result = try await pipeline.detect(in: frame, cache: cache)

    // Detector skipped.
    #expect(await counter.count == 0)
    // Returned value is the cached entry, not `[]`.
    #expect(result.map(\.label) == ["cached-sentinel"])
    #expect(result.first?.boundingBox == sentinel.boundingBox)
}

/// Two invocations at timestamps that map to the same 30 fps quantization
/// bucket (1.000s and 1.012s round to the same `1/30s × 30` slot). The
/// pipeline gates on `contains(timestamp:)`, which is bucket-aware, so the
/// second call short-circuits — this distinguishes the bucket-aware gate
/// from raw `CMTime` equality.
@Test
@MainActor
func cacheHitIsBucketAware() async throws {
    let counter = CallCounter()
    let detector = RecordingDetector(counter: counter, detections: [makeDetection()])
    let pipeline = DetectorPipeline(detector)
    let cache = ResultStore()  // default 1/30s quantization
    let firstFrame = makeSyntheticFrame(
        timestamp: CMTime(value: 1000, timescale: 1000)  // 1.000s
    )
    let neighborFrame = makeSyntheticFrame(
        timestamp: CMTime(value: 1012, timescale: 1000)  // 1.012s — same 30fps bucket
    )

    _ = try await pipeline.detect(in: firstFrame, cache: cache)
    _ = try await pipeline.detect(in: neighborFrame, cache: cache)

    #expect(await counter.count == 1)
}

/// `cache: nil` reproduces pre-Phase-2 behavior: every call runs the
/// detector, no skip-gate, no write-through.
@Test
func nilCachePreservesUncachedBehavior() async throws {
    let counter = CallCounter()
    let detector = RecordingDetector(counter: counter, detections: [makeDetection()])
    let pipeline = DetectorPipeline(detector)
    let frame = makeSyntheticFrame(timestamp: CMTime(value: 1000, timescale: 1000))

    _ = try await pipeline.detect(in: frame, cache: nil)
    _ = try await pipeline.detect(in: frame, cache: nil)

    #expect(await counter.count == 2)
}

/// Cache-miss with multiple detectors fans out in parallel exactly as
/// pre-Phase-2 — both detectors run, both call counters tick, results
/// concatenate in the order detectors were supplied.
@Test
@MainActor
func cacheMissParallelFanoutPreserved() async throws {
    let counterA = CallCounter()
    let counterB = CallCounter()
    let detectorA = RecordingDetector(
        identifier: "a",
        counter: counterA,
        detections: [makeDetection(label: "a")]
    )
    let detectorB = RecordingDetector(
        identifier: "b",
        counter: counterB,
        detections: [makeDetection(label: "b")]
    )
    let pipeline = DetectorPipeline(detectorA, detectorB)
    let cache = ResultStore()
    let frame = makeSyntheticFrame(timestamp: CMTime(value: 1000, timescale: 1000))

    let result = try await pipeline.detect(in: frame, cache: cache)

    #expect(await counterA.count == 1)
    #expect(await counterB.count == 1)
    #expect(result.map(\.label) == ["a", "b"])
}
