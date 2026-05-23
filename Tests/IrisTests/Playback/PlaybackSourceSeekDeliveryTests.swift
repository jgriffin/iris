import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import Iris

// MARK: - Fixture

/// Same M2 LFS-tracked smoke clip used elsewhere — 1280×720, h.264, 30 fps,
/// ~9.47s. Re-resolved here so this stress test stands alone.
private func fixtureURL() throws -> URL {
    try #require(
        Bundle.module.url(forResource: "clipboard-blank-page", withExtension: "mp4"),
        """
        Missing fixture clipboard-blank-page.mp4 — \
        run `git lfs install && git lfs pull` after clone.
        """
    )
}

// MARK: - Test double

/// Thread-safe recorder for observed `Frame.timestamp` values. `Detector`
/// conformers must be `Sendable`; this `actor` lets the `SlowRecordingDetector`
/// `struct` share mutable state without `@unchecked`.
private actor TimestampRecorder {
    private(set) var observed: [CMTime] = []
    func record(_ t: CMTime) { observed.append(t) }
    func snapshot() -> [CMTime] { observed }
    func count() -> Int { observed.count }
}

/// `Detector` test double that sleeps `delay` per call before returning,
/// recording each frame's `timestamp`. The deliberate inference delay puts
/// the consumer mid-`detect(in:)` whenever the *next* frame arrives — that
/// is the precondition for the `.bufferingNewest(N)` policy to matter at
/// all. With `(1)`, a seek-emitted frame that lands while a detection is
/// in flight is silently dropped; with `(3)`, it survives the wait.
private struct SlowRecordingDetector: Detector {
    let availability: DetectorAvailability = .available
    let modelIdentifier: String = "slow-recording"
    let delay: Duration
    let recorder: TimestampRecorder

    func prewarm() async {}

    func detect(in frame: Frame) async throws -> [Detection] {
        await recorder.record(frame.timestamp)
        try? await Task.sleep(for: delay)
        return []
    }
}

// MARK: - Stress test

/// **Phase 3 stress test.** Drive a real `PlaybackSource` through a
/// detector that takes 100ms per frame — guaranteed mid-inference when the
/// next source tick arrives at the clip's 30fps native cadence (~33ms).
/// After playback has run long enough that the detector is reliably in
/// flight, issue a backward `seek(to:)` and assert that the
/// seek-emitted frame's timestamp is eventually observed by the detector.
///
/// **What this guards.** Under `.bufferingNewest(1)` this assertion fails:
/// the seek-emit lands in the buffer, the next tick after the in-flight
/// detection completes overwrites it before the consumer reads, no
/// detection ever runs at the seek target. Under `.bufferingNewest(3)`,
/// the seek-emit survives the wait and is delivered.
///
/// **Flake tolerance.** Detector delay is deterministic `Task.sleep`. The
/// assertion is "seek target observed within the post-seek frames the
/// consumer reads before the test deadline" — a lower-bounded eventual
/// check, not a tight ordering one. If this flakes on local CI under
/// load, the Phase 4 manual smoke is the durable acceptance test
/// (`plans/features/playback-detection-cache.md` §Phase 3 explicitly
/// authorizes the FIXME fallback).
@Test
func seekFrameSurvivesMidInferenceUnderBufferingNewest3() async throws {
    let url = try fixtureURL()
    // `TaskTickDriver(hz: 30)` — match the clip's native cadence so the
    // 100ms-per-frame detector reliably overlaps the next tick.
    let source = PlaybackSource(url: url, driver: TaskTickDriver(hz: 30))

    let recorder = TimestampRecorder()
    let detector = SlowRecordingDetector(
        delay: .milliseconds(100),
        recorder: recorder
    )

    // Consumer mirrors the real-world detector loop: sequential
    // `for await` + per-frame `detect`. This is the exact shape that
    // `.bufferingNewest(1)` was racing against.
    let consumerTask = Task {
        for await frame in source.frames {
            _ = try? await detector.detect(in: frame)
        }
    }
    defer { consumerTask.cancel() }

    try await source.start()

    // Wait until the detector has observed ~5 frames — enough to be
    // confidently mid-inference when we issue the seek. 5 × 100ms ≈ 500ms
    // wall time, plus driver scheduling slack.
    let warmupDeadline = ContinuousClock().now + .seconds(3)
    while await recorder.count() < 5, ContinuousClock().now < warmupDeadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(
        await recorder.count() >= 5,
        "detector did not observe enough warmup frames before seek"
    )

    // Backward seek to a timestamp earlier than anywhere we've played.
    // The clip is ~9.47s; warmup at 30fps × 5 frames ≈ 0.166s of asset
    // time, but `play()` advances the player itself in real time, so by
    // warmup-end the player is at ~0.5–1.0s of asset time. Seek target
    // 0.2s is comfortably earlier than the play head, validating the
    // "never-played region" failure mode the bug describes.
    //
    // Pause immediately after seek so subsequent 30Hz ticks don't
    // compete for the buffer slot — the test is about whether the
    // seek-emitted frame survives the in-flight detection, not about
    // whether the buffer survives sustained 30Hz pressure. With
    // `.bufferingNewest(1)` this still fails (the seek-emit is
    // overwritten by the in-flight tick that races with it); with
    // `.bufferingNewest(3)` it passes.
    let seekTarget = CMTime(seconds: 0.2, preferredTimescale: 600)
    try await source.seek(to: seekTarget)
    await source.pause()

    // Tolerance: one frame of 30fps source ≈ 33ms. Allow 1.5× for the
    // standard frame-accurate seek slop AVF documents.
    let tolerance: Double = (1.0 / 30.0) * 1.5
    let targetSeconds = seekTarget.seconds

    // Wait for the seek-emitted timestamp to land in the recorder.
    // Upper bound generous: the consumer is doing 100ms detections, so
    // even with the seek-emit at the head of the queue, the wait is at
    // least one in-flight detection + the seek's own detection. 3s is
    // comfortably over that under load.
    let assertionDeadline = ContinuousClock().now + .seconds(3)
    var sawSeekTimestamp = false
    while ContinuousClock().now < assertionDeadline {
        let observed = await recorder.snapshot()
        if observed.contains(where: { abs($0.seconds - targetSeconds) <= tolerance }) {
            sawSeekTimestamp = true
            break
        }
        try await Task.sleep(for: .milliseconds(50))
    }

    let observedSeconds = await recorder.snapshot().map(\.seconds)
    #expect(
        sawSeekTimestamp,
        """
        Detector never observed a frame near the seek target \(targetSeconds)s. \
        Observed (seconds): \(observedSeconds). \
        With .bufferingNewest(1) this is expected to fail; with \
        .bufferingNewest(3) it should pass.
        """
    )

    await source.invalidate()
}
