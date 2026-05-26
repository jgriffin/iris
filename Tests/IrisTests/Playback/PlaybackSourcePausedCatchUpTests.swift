import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import Iris

// MARK: - Fixture

/// `dancer-full-body.mp4` — 1280×720, single full-body dancer. The body-pose
/// detector fires reliably on it (see `VisionBodyPoseDetectorFixtureTests`),
/// which is what makes it the right clip for proving the catch-up path
/// yields a *detection*, not just a frame.
private func dancerURL() throws -> URL {
    try #require(
        Bundle.module.url(forResource: "dancer-full-body", withExtension: "mp4"),
        """
        Missing fixture dancer-full-body.mp4 — \
        run `git lfs install && git lfs pull` after clone.
        """
    )
}

// MARK: - Paused catch-up test

/// **FIX 4 guard.** The demos re-emit the current frame on detector-swap /
/// pause-tuning via `source.seek(to: controller.currentTime)`. The contract
/// being exercised: a `seek(to:)` on an `.idle` (paused, never-played)
/// source emits a one-shot frame at the target time *even though no tick
/// driver is running* (`PlaybackSource.emitOneShotFrame()`), and a detector
/// draining `source.frames` consumes that frame and produces a detection.
///
/// This proves the "paused catch-up re-detects the visible frame" behavior
/// the demos rely on after the FIX 1 detection-loop-stays-alive change:
/// without it, a paused source that swaps detector would show no detections
/// because no frame ever reaches the consumer.
///
/// Deterministic: the source is never `play()`-ed, so the only frame that
/// can arrive is the seek-emitted one. We seek to a specific asset time and
/// assert (a) a frame near that timestamp is delivered and (b) the body-pose
/// detector fires on it.
@Test
func pausedSeekEmitsFreshFrameAndYieldsDetection() async throws {
    let url = try dancerURL()
    // Use the headless `TaskTickDriver` default but never start playback —
    // the source stays `.idle`, so the seek's one-shot read is the only
    // path that can produce a frame. (The driver is irrelevant here; the
    // seek-emit is independent of it.)
    let source = PlaybackSource(url: url)

    let detector = VisionBodyPoseDetector()

    // Record what the consumer observes. The consumer mirrors the demo's
    // detection loop: drain `frames`, run the detector per frame.
    let recorder = SeekCatchUpRecorder()
    let consumerTask = Task {
        for await frame in source.frames {
            let detections = (try? await detector.detect(in: frame)) ?? []
            await recorder.record(timestamp: frame.timestamp, detectionCount: detections.count)
        }
    }
    defer { consumerTask.cancel() }

    // Seek to a mid-clip timestamp while paused (no `play()`). This is the
    // exact primitive the demos invoke for paused catch-up. `seek(to:)`
    // resets the monotonicity guard and emits one frame at the target.
    let seekTarget = CMTime(seconds: 1.0, preferredTimescale: 600)
    try await source.seek(to: seekTarget)

    // Wait for the consumer to observe the seek-emitted frame. The seek's
    // own `emitOneShotFrame` already polled for buffer readiness, so this
    // is just waiting for the async consumer to drain + run the detector.
    let targetSeconds = seekTarget.seconds
    // One source frame at 30fps ≈ 33ms; allow 1.5× for AVF's documented
    // frame-accurate seek slop.
    let tolerance = (1.0 / 30.0) * 1.5

    let deadline = ContinuousClock().now + .seconds(5)
    var match: (timestamp: Double, detectionCount: Int)?
    while ContinuousClock().now < deadline {
        let observed = await recorder.snapshot()
        if let hit = observed.first(where: { abs($0.timestamp - targetSeconds) <= tolerance }) {
            match = hit
            break
        }
        try await Task.sleep(for: .milliseconds(50))
    }

    let observedSeconds = await recorder.snapshot().map(\.timestamp)
    let resolved = try #require(
        match,
        """
        Paused seek did not deliver a fresh frame near \(targetSeconds)s to the \
        consumer. Observed (seconds): \(observedSeconds). If this fails, the \
        paused catch-up path is BROKEN — the seek-emitted frame never reached \
        the detector loop.
        """
    )

    // The catch-up frame must actually yield a detection — the dancer clip
    // poses well at 1.0s, so the body-pose detector should fire.
    #expect(
        resolved.detectionCount >= 1,
        """
        Catch-up frame at \(resolved.timestamp)s was delivered but produced no \
        detection. The frame reached the consumer but the detector did not fire \
        on it.
        """
    )

    await source.invalidate()
}

// MARK: - Test double

/// Thread-safe recorder of observed `(timestamp, detectionCount)` pairs.
/// `actor` so the `Sendable` consumer task can append without `@unchecked`.
private actor SeekCatchUpRecorder {
    private(set) var observed: [(timestamp: Double, detectionCount: Int)] = []

    func record(timestamp: CMTime, detectionCount: Int) {
        observed.append((timestamp: timestamp.seconds, detectionCount: detectionCount))
    }

    func snapshot() -> [(timestamp: Double, detectionCount: Int)] { observed }
}
