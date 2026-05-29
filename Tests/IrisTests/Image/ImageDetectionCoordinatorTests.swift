import CoreGraphics
import CoreMedia
import Foundation
import Testing

@testable import Iris

// MARK: - Test goal
//
// `ImageDetectionCoordinator` (M8·P3) is the one-shot image analogue of
// `PlaybackDetectionCoordinator`: it holds a still `Frame`, runs the composed
// `DetectionRunner` once on load, and re-runs that same held frame on a detector
// swap. These tests pin the three contracts the spec calls out — load → detect,
// swap → re-detect the held frame (the headline, mirroring the playback swap
// regression), and the per-image cache + metrics reset — plus that `clear`
// drops the session and the held image.
//
// Unlike the playback coordinator there is no detect loop: `setImage` /
// `selectDetector` `await runner.run(on:)` to completion, so the cache is
// populated the instant the call returns — assertions read it directly, no poll.

// MARK: - Fixtures (synthesized — no committed binary)

/// Build a small upright still `Frame` via the real `ImageFrameDecoder`, so the
/// coordinator runs on the same source-agnostic `Frame` the demo's image picker
/// produces. Defaults to a frozen `.zero` timestamp (the decoder's contract), so
/// the cache bucket under test is the zero bucket.
private func makeImageFrame(width: Int = 64, height: Int = 64, identifier: String = "fixture") throws -> Frame {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo =
        CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue
    guard
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo
        )
    else { fatalError("CGContext creation failed") }
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else { fatalError("makeImage failed") }
    return try ImageFrameDecoder().frame(from: image, identifier: identifier)
}

/// Two `MockDetector`s with distinct labels so we can tell which one's output
/// landed in the cache — the same A/B fixture the playback swap test uses, via
/// non-tunable (`PassthroughRouter`) catalog entries.
private enum DetectorAB {
    static let labelA = "alpha"
    static let labelB = "beta"

    static func detection(label: String) -> Detection {
        Detection(
            boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1),
            label: label,
            confidence: 1.0,
            sourceModelID: label
        )
    }

    @MainActor
    static func entry(label: String) -> DetectorCatalogEntry {
        .make(id: "mock.\(label)", displayName: label) {
            MockDetector(detections: [detection(label: label)], modelIdentifier: label)
        }
    }
}

// MARK: - Tests

@MainActor
@Suite struct ImageDetectionCoordinatorTests {

    /// Load an image with detector A → A's output is cached at the held frame's
    /// timestamp, the frame is held, and the session is installed. The one-shot
    /// `run` is awaited, so the cache is populated by the time `setImage` returns.
    @Test func setImageDetectsHeldFrameOnce() async throws {
        let frame = try makeImageFrame()
        let coordinator = ImageDetectionCoordinator()

        await coordinator.setImage(frame, detector: DetectorAB.entry(label: DetectorAB.labelA))

        #expect(coordinator.frame?.source == frame.source)
        #expect(coordinator.session != nil)
        let hits = coordinator.resultStore.lookup(at: frame.timestamp)
        #expect(
            hits.contains { $0.label == DetectorAB.labelA },
            "Detector A's output should be cached at the held frame's timestamp after load"
        )
    }

    /// **The swap test (the headline).** Load with A, swap to B, and assert the
    /// held frame is now detected by B — never A. The image analogue of the
    /// playback swap regression: `selectDetector` invalidates the cache, installs
    /// B in place, and re-runs the held frame, so B's output replaces A's at the
    /// same bucket and no stale A entry survives.
    @Test func swappingDetectorReDetectsHeldFrameWithNewDetector() async throws {
        let frame = try makeImageFrame()
        let coordinator = ImageDetectionCoordinator()

        await coordinator.setImage(frame, detector: DetectorAB.entry(label: DetectorAB.labelA))
        #expect(
            coordinator.resultStore.lookup(at: frame.timestamp).contains { $0.label == DetectorAB.labelA },
            "Detector A's output should be cached before the swap"
        )

        await coordinator.selectDetector(DetectorAB.entry(label: DetectorAB.labelB))

        let hits = coordinator.resultStore.lookup(at: frame.timestamp)
        #expect(
            hits.contains { $0.label == DetectorAB.labelB },
            "After the swap the held frame should be detected by B"
        )
        #expect(
            !hits.contains { $0.label == DetectorAB.labelA },
            "After the swap a stale A entry must not survive at the held bucket"
        )
    }

    /// `selectDetector` is a no-op when no image is held — no session, no crash.
    @Test func selectDetectorWithoutImageIsNoOp() async {
        let coordinator = ImageDetectionCoordinator()
        await coordinator.selectDetector(DetectorAB.entry(label: DetectorAB.labelA))
        #expect(coordinator.session == nil)
        #expect(coordinator.frame == nil)
    }

    /// `setImage` resets the metrics gauge and invalidates the cache so a new
    /// still starts from a clean slate — no carried-over counts or stale
    /// detections from a prior image.
    @Test func setImageResetsMetricsAndInvalidatesCache() async throws {
        let coordinator = ImageDetectionCoordinator()

        // Pre-load the cache + metrics with junk that must not survive a new image.
        coordinator.metrics.recordInference(seconds: 0.05)
        coordinator.resultStore.append(
            TimestampedDetections(timestamp: .zero, detections: [DetectorAB.detection(label: "stale")])
        )
        #expect(coordinator.metrics.processedCount == 1)
        #expect(!coordinator.resultStore.lookup(at: .zero).isEmpty)

        let frame = try makeImageFrame()
        await coordinator.setImage(frame, detector: DetectorAB.entry(label: DetectorAB.labelA))

        // The "stale" pre-seed is gone; only A's fresh output occupies the bucket.
        let hits = coordinator.resultStore.lookup(at: frame.timestamp)
        #expect(
            !hits.contains { $0.label == "stale" },
            "The pre-seeded stale entry should be invalidated by setImage"
        )
        #expect(hits.contains { $0.label == DetectorAB.labelA })
    }

    /// `clear` drops the session and the held image and clears the cache.
    @Test func clearDropsSessionAndImage() async throws {
        let frame = try makeImageFrame()
        let coordinator = ImageDetectionCoordinator()
        await coordinator.setImage(frame, detector: DetectorAB.entry(label: DetectorAB.labelA))
        #expect(coordinator.session != nil)
        #expect(coordinator.frame != nil)

        coordinator.clear()

        #expect(coordinator.session == nil)
        #expect(coordinator.frame == nil)
        #expect(coordinator.resultStore.lookup(at: frame.timestamp).isEmpty)
    }
}
