import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import Iris

// MARK: - Fixture

/// The M2 LFS-tracked smoke clip. 1280×720, h.264, 30 fps, ~9.47s, 284
/// frames. Same fixture used by `VisionRectanglesDetectorFixtureTests` —
/// resolved via `Bundle.module` because `Package.swift` declares
/// `resources: [.process("Fixtures")]` on the test target.
private func fixtureURL() throws -> URL {
    try #require(
        Bundle.module.url(forResource: "clipboard-blank-page", withExtension: "mp4"),
        """
        Missing fixture clipboard-blank-page.mp4 — \
        run `git lfs install && git lfs pull` after clone.
        """
    )
}

// MARK: - Tests

/// End-to-end smoke: `PlaybackSource` decodes a real `.mp4` file and emits
/// frames on its `AsyncStream<Frame>` until EOF.
///
/// Assertions:
///   1. Frame timestamps are monotonically non-decreasing in
///      `CMTime.seconds` (per the asset-time semantics documented on
///      `Frame.timestamp`).
///   2. Total emitted frame count lands within a permissive band of
///      `duration × [20, 70]` Hz. The lower bound covers a slow CI host
///      that polls below the clip's 30 fps native rate; the upper bound
///      covers a ProMotion 120 Hz driver. Exact match isn't possible
///      because the driver tick rate and the asset's native frame rate
///      are independent.
///   3. The `AsyncStream` finishes when `AVPlayerItem.didPlayToEndTimeNotification`
///      fires — so `for await frame in source.frames` terminates
///      naturally without manual cancellation.
@Test
func playbackSourceEmitsMonotonicFramesUntilEOF() async throws {
    let url = try fixtureURL()

    // 60 Hz driver matches the doc-stated "nominal display rate" in
    // `PlaybackSource`. The test runs the clip at native (1×) speed —
    // tried 4× via `player.rate` but pre-play rate manipulation is
    // racy against AVF's async asset-load. Native rate keeps the test
    // deterministic; wall-clock runtime is ~10s (clip duration), well
    // inside the 20s collection deadline.
    let driver = TaskTickDriver(hz: 60)
    let source = PlaybackSource(url: url, driver: driver)

    try await source.start()

    var lastSeconds: Double = -1
    var frameCount = 0
    let collectDeadline = ContinuousClock().now + .seconds(20)

    for await frame in source.frames {
        let seconds = frame.seconds
        #expect(
            seconds + 1e-6 >= lastSeconds,
            "non-monotonic playback timestamp: \(seconds) < \(lastSeconds)"
        )
        lastSeconds = seconds
        frameCount += 1

        if ContinuousClock().now > collectDeadline {
            Issue.record("PlaybackSource stream did not finish within 20s")
            await source.invalidate()
            break
        }
    }

    // Clip is ~9.47s; permissive band per the test doc.
    let durationSeconds = 9.466
    let lowerBound = Int(durationSeconds * 20)  // ≈ 189
    let upperBound = Int(durationSeconds * 70)  // ≈ 662
    #expect(
        frameCount >= lowerBound,
        "Too few frames: \(frameCount) (lower bound \(lowerBound))"
    )
    #expect(
        frameCount <= upperBound,
        "Too many frames: \(frameCount) (upper bound \(upperBound))"
    )

    await source.invalidate()
}

/// Frames carry asset time, not host clock — verify by inspecting the first
/// few frames: their `seconds` should start near 0 (asset start), not at
/// the test process's wall-clock host time (which is in the billions).
@Test
func playbackSourceTimestampsAreAssetTimeNotHostClock() async throws {
    let url = try fixtureURL()
    let source = PlaybackSource(url: url, driver: TaskTickDriver(hz: 60))

    try await source.start()

    var firstSeconds: Double?
    let deadline = ContinuousClock().now + .seconds(5)

    for await frame in source.frames {
        if firstSeconds == nil { firstSeconds = frame.seconds }
        // Three frames is enough to confirm the timestamp clock.
        if (firstSeconds ?? 0) > 0.5 { break }
        if ContinuousClock().now > deadline { break }
    }

    await source.invalidate()

    let first = try #require(firstSeconds, "Source emitted no frames")
    // Asset time starts at zero; allow up to 1s of playback before the
    // first frame is observed (host-clock would be ~10^9).
    #expect(
        first < 2.0,
        "First frame timestamp \(first) is too large to be asset time"
    )
    #expect(
        first >= 0,
        "First frame timestamp \(first) is negative"
    )
}
