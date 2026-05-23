import CoreGraphics
import CoreMedia
import CoreVideo
import Testing

@testable import Iris

// MARK: - Test goal
//
// Per `plans/features/M4.md` Phase 2: route `TuningModel.update(_:to:)`
// outputs through the three tiers and verify the pipeline picks up
// the side-effects.
//
//   - View-tier change → no detector rebuild, no cache invalidation.
//   - Filter-tier change → settings mutated; pipeline filter pass
//     applies to *both* cache hits and fresh inferences.
//   - Detector-tier change → detector reference swapped, cache cleared.
//
// Uses a `RecordingTunableDetector` test double that records its
// `apply(_:)` calls + a configurable verdict, alongside a real
// `ResultStore` cache.

// MARK: - Helpers

private func makeSyntheticFrame(
    timestamp: CMTime,
    width: Int = 32,
    height: Int = 24
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
        source: .mock("tuning-pipeline-routing-tests"),
        format: .yuv420BiPlanarFull,
        dimensions: CGSize(width: width, height: height)
    )
}

private func makeDetection(label: String, confidence: Float) -> Detection {
    Detection(
        boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
        label: label,
        confidence: confidence,
        sourceModelID: "recording-tunable"
    )
}

// MARK: - Recording double

/// Trivial settings type — one Float knob, schema-correct, so we can
/// route changes through the model without invoking the real Vision
/// classifier. Lets each test fix the verdict the recording detector
/// will return.
private struct RecordingSettings: DetectorSettings {
    var threshold: Float = 0.5
    static var schema: SettingSchema {
        SettingSchema(knobs: [
            SettingSchema.Knob(
                key: "threshold",
                label: "Threshold",
                kind: .float(range: 0.0...1.0, step: 0.01, default: 0.5),
                tier: .detector
            )
        ])
    }
    static func key(for keyPath: PartialKeyPath<Self>) -> String? {
        switch keyPath {
        case \Self.threshold: return "threshold"
        default: return nil
        }
    }
}

/// `TunableDetector` test double. `apply(_:)` returns the configured
/// verdict and records the change for later inspection; `detect(in:)`
/// emits a configurable detection list so output-filter behavior is
/// observable.
private final class RecordingTunableDetector: TunableDetector, @unchecked Sendable {
    typealias Settings = RecordingSettings

    let settings: RecordingSettings
    let availability: DetectorAvailability = .available
    let modelIdentifier: String = "recording-tunable"

    // Apply verdict configuration + recording. `verdict` is a closure
    // so each test wires its tier; `recordedChanges` collects every
    // change observed.
    var verdict: @Sendable (SettingChange) -> ApplyResult = { _ in .view }
    private(set) var recordedChanges: [SettingChange] = []
    var detections: [Detection] = []
    private(set) var detectCount = 0

    init(settings: RecordingSettings = RecordingSettings()) {
        self.settings = settings
    }

    func prewarm() async {}

    func detect(in _: Frame) async throws -> [Detection] {
        detectCount += 1
        return detections
    }

    func apply(_ change: SettingChange) -> ApplyResult {
        recordedChanges.append(change)
        return verdict(change)
    }
}

// MARK: - View-tier

@Test
@MainActor
func viewTierChangeDoesNotRebuildOrInvalidate() async throws {
    let detector = RecordingTunableDetector()
    detector.verdict = { _ in .view }
    let cache = ResultStore()
    let model = TuningModel(detector: detector, cache: cache)

    // Pre-seed the cache so we can detect an unwanted invalidation.
    let timestamp = CMTime(value: 1000, timescale: 1000)
    cache.append(
        TimestampedDetections(
            timestamp: timestamp,
            detections: [makeDetection(label: "seeded", confidence: 0.9)]
        )
    )

    model.update(\.threshold, to: 0.6)

    #expect(model.lastApplyTier == .view)
    #expect(detector.recordedChanges.count == 1)
    // Detector reference unchanged.
    #expect(model.detector === detector)
    // Cache survives (give the invalidation Task a chance to land — it
    // shouldn't, but the async-Task path means we need a yield to be
    // sure).
    await Task.yield()
    #expect(cache.contains(timestamp: timestamp))
}

// MARK: - Filter-tier

@Test
@MainActor
func filterTierLeavesDetectorAndCacheIntact() async throws {
    let detector = RecordingTunableDetector()
    detector.verdict = { _ in .filter }
    let cache = ResultStore()
    let model = TuningModel(detector: detector, cache: cache)

    let timestamp = CMTime(value: 1000, timescale: 1000)
    cache.append(
        TimestampedDetections(
            timestamp: timestamp,
            detections: [makeDetection(label: "seeded", confidence: 0.9)]
        )
    )

    model.update(\.threshold, to: 0.6)
    await Task.yield()

    #expect(model.lastApplyTier == .filter)
    #expect(model.detector === detector)
    #expect(cache.contains(timestamp: timestamp))
}

@Test
@MainActor
func pipelineAppliesTuningFilterOnCacheHit() async throws {
    let detector = RecordingTunableDetector()
    let cache = ResultStore()
    let model = TuningModel(detector: detector, cache: cache)

    // Cache holds a mix of low- and high-confidence detections.
    let timestamp = CMTime(value: 1000, timescale: 1000)
    cache.append(
        TimestampedDetections(
            timestamp: timestamp,
            detections: [
                makeDetection(label: "lo", confidence: 0.2),
                makeDetection(label: "hi", confidence: 0.9),
            ]
        )
    )

    // Install a confidence-floor filter via the tuning model's slot.
    model.filter = { $0.confidence >= 0.5 }

    let pipeline = DetectorPipeline(detector)
    let frame = makeSyntheticFrame(timestamp: timestamp)

    let result = try await pipeline.detect(in: frame, cache: cache, tuning: model)

    // Filter applied: only the high-confidence detection survives.
    #expect(result.map(\.label) == ["hi"])
    // Detector dispatch was skipped (cache hit).
    #expect(detector.detectCount == 0)
    // Cache itself is *not* rewritten by the filter — still holds the
    // unfiltered pair.
    let cached = cache.fetch(timestamp: timestamp)?.detections ?? []
    #expect(cached.count == 2)
}

@Test
@MainActor
func pipelineAppliesTuningFilterOnFreshInference() async throws {
    let detector = RecordingTunableDetector()
    detector.detections = [
        makeDetection(label: "lo", confidence: 0.2),
        makeDetection(label: "hi", confidence: 0.9),
    ]
    let cache = ResultStore()
    let model = TuningModel(detector: detector, cache: cache)
    model.filter = { $0.confidence >= 0.5 }

    let pipeline = DetectorPipeline(detector)
    let timestamp = CMTime(value: 2000, timescale: 1000)
    let frame = makeSyntheticFrame(timestamp: timestamp)

    let result = try await pipeline.detect(in: frame, cache: cache, tuning: model)

    #expect(result.map(\.label) == ["hi"])
    #expect(detector.detectCount == 1)
    // Cache write-through preserves the *unfiltered* output — that's
    // the M4 doctrine (cache = model's ground truth; filter = view).
    let cached = cache.fetch(timestamp: timestamp)?.detections ?? []
    #expect(cached.count == 2)
}

// MARK: - Detector-tier

@Test
@MainActor
func detectorTierSwapsDetectorAndInvalidatesCache() async throws {
    let original = RecordingTunableDetector()
    let cache = ResultStore()
    let model = TuningModel(detector: original, cache: cache)

    // Pre-seed cache; we expect the detector-tier path to drop it.
    let timestamp = CMTime(value: 1000, timescale: 1000)
    cache.append(
        TimestampedDetections(
            timestamp: timestamp,
            detections: [makeDetection(label: "seeded", confidence: 0.9)]
        )
    )
    #expect(cache.contains(timestamp: timestamp))

    let rebuilt = RecordingTunableDetector()
    original.verdict = { _ in .detector(rebuilt: rebuilt) }

    model.update(\.threshold, to: 0.9)

    // Yield so the cache-invalidation Task gets a chance to run.
    await Task.yield()
    await Task.yield()

    #expect(model.lastApplyTier == .detector)
    #expect(model.detector === rebuilt)
    #expect(cache.contains(timestamp: timestamp) == false)
}

@Test
@MainActor
func detectorTierWithNilRebuildKeepsCurrentDetectorButInvalidates() async throws {
    // Belt-and-suspenders: if a conformer slips through with a nil
    // rebuild payload (Phase 1 vestige), the model leaves the current
    // detector in place but still invalidates the cache — safer than
    // ignoring the verdict.
    let detector = RecordingTunableDetector()
    let cache = ResultStore()
    let model = TuningModel(detector: detector, cache: cache)

    let timestamp = CMTime(value: 1000, timescale: 1000)
    cache.append(
        TimestampedDetections(
            timestamp: timestamp,
            detections: [makeDetection(label: "seeded", confidence: 0.9)]
        )
    )

    detector.verdict = { _ in .detector(rebuilt: nil) }
    model.update(\.threshold, to: 0.9)
    await Task.yield()
    await Task.yield()

    #expect(model.detector === detector)  // unchanged on nil rebuild
    #expect(cache.contains(timestamp: timestamp) == false)
}

// MARK: - Pipeline picks up swapped detector

@Test
@MainActor
func pipelineUsesTuningRouterCurrentDetectorWhenPresent() async throws {
    let original = RecordingTunableDetector()
    original.detections = [makeDetection(label: "from-original", confidence: 0.9)]
    let replacement = RecordingTunableDetector()
    replacement.detections = [makeDetection(label: "from-replacement", confidence: 0.9)]

    let cache = ResultStore()
    let model = TuningModel(detector: original, cache: cache)

    // Pipeline holds the *original* detector; tuning router will
    // shadow it once we swap.
    let pipeline = DetectorPipeline(original)

    // Before swap: pipeline's own detector runs.
    let timestamp1 = CMTime(value: 1000, timescale: 1000)
    let frame1 = makeSyntheticFrame(timestamp: timestamp1)
    let r1 = try await pipeline.detect(in: frame1, cache: cache, tuning: model)
    #expect(r1.map(\.label) == ["from-original"])

    // Trigger a detector-tier swap.
    original.verdict = { _ in .detector(rebuilt: replacement) }
    model.update(\.threshold, to: 0.9)
    await Task.yield()
    await Task.yield()

    // After swap: pipeline picks up the router's current detector.
    let timestamp2 = CMTime(value: 2000, timescale: 1000)
    let frame2 = makeSyntheticFrame(timestamp: timestamp2)
    let r2 = try await pipeline.detect(in: frame2, cache: cache, tuning: model)
    #expect(r2.map(\.label) == ["from-replacement"])
}
