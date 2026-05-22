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

// MARK: - Phase 2: seek + step

/// Fixture parameters — 30 fps clip, ~9.47s. Frame duration ≈ 1/30s; a
/// 1.5× tolerance gives us ~50ms latitude for frame-accurate seek
/// assertions.
private let fixtureFPS: Double = 30.0
private let fixtureFrameDuration: Double = 1.0 / fixtureFPS
private let fixtureSeekToleranceSeconds: Double = fixtureFrameDuration * 1.5

/// Wait for `playerItem.duration` to load. The fixture's asset loads
/// lazily; `duration` is `.indefinite` until the item is ready-to-play.
/// Used by clamp tests that need a concrete duration to construct an
/// "out of range" target.
private func waitForDuration(_ source: PlaybackSource) async throws -> CMTime {
    let deadline = ContinuousClock().now + .seconds(3)
    while ContinuousClock().now < deadline {
        let d = source.testHooks.playerItem.duration
        if d.isValid, !d.isIndefinite, CMTimeCompare(d, .zero) > 0 {
            return d
        }
        try await Task.sleep(nanoseconds: 20_000_000)  // 20ms
    }
    Issue.record("Fixture duration never loaded")
    return .invalid
}

/// Collect frames off the source's `frames` stream into a holder so seek/
/// step tests can assert on what was emitted. Holder uses an `actor` so
/// the collector task and the test thread synchronize cleanly under
/// strict concurrency.
private actor FrameCollector {
    private var frames: [Frame] = []
    func append(_ frame: Frame) { frames.append(frame) }
    func snapshot() -> [Frame] { frames }
    func last() -> Frame? { frames.last }
    func count() -> Int { frames.count }
}

/// `seek` to a mid-clip time yields a `Frame` with `timestamp` matching the
/// seek target (within frame-duration × 1.5 tolerance).
@Test
func seekToMidClipYieldsFrameNearTarget() async throws {
    let url = try fixtureURL()
    let source = PlaybackSource(url: url, driver: ManualTickDriver())

    let collector = FrameCollector()
    let collectTask = Task {
        for await frame in source.frames {
            await collector.append(frame)
        }
    }
    defer { collectTask.cancel() }

    let target = CMTime(seconds: 3.0, preferredTimescale: 600)
    try await source.seek(to: target)

    // Give the AsyncStream a beat to deliver — yield + a tiny sleep is
    // enough; the seek already awaited the AVF completion.
    try await Task.sleep(nanoseconds: 50_000_000)

    let emitted = await collector.last()
    let frame = try #require(emitted, "seek did not yield a frame")
    let delta = abs(frame.seconds - 3.0)
    #expect(
        delta <= fixtureSeekToleranceSeconds,
        "seek-to-3.0s yielded frame at \(frame.seconds); delta \(delta) > tolerance \(fixtureSeekToleranceSeconds)"
    )

    await source.invalidate()
}

/// `seek(to:)` with a negative `CMTime` clamps to `.zero` — verified by the
/// resulting frame's timestamp being ≈ 0.
@Test
func seekToNegativeTimeClampsToZero() async throws {
    let url = try fixtureURL()
    let source = PlaybackSource(url: url, driver: ManualTickDriver())

    let collector = FrameCollector()
    let collectTask = Task {
        for await frame in source.frames {
            await collector.append(frame)
        }
    }
    defer { collectTask.cancel() }

    // Negative target — clamp expected to `.zero`.
    let target = CMTime(seconds: -5.0, preferredTimescale: 600)
    try await source.seek(to: target)
    try await Task.sleep(nanoseconds: 50_000_000)

    // `playerItem.currentTime()` is the source of truth — should sit at
    // `.zero` after the clamp.
    let currentTime = source.testHooks.playerItem.currentTime()
    #expect(
        currentTime.seconds <= fixtureSeekToleranceSeconds,
        "negative seek did not clamp to .zero — currentTime is \(currentTime.seconds)"
    )

    // If a frame emitted, its timestamp should also reflect the clamp.
    if let frame = await collector.last() {
        #expect(
            frame.seconds <= fixtureSeekToleranceSeconds,
            "negative-clamped seek yielded frame at \(frame.seconds), expected ≤ \(fixtureSeekToleranceSeconds)"
        )
    }

    await source.invalidate()
}

/// `seek(to:)` past `duration` clamps to `duration`.
@Test
func seekPastDurationClampsToDuration() async throws {
    let url = try fixtureURL()
    let source = PlaybackSource(url: url, driver: ManualTickDriver())

    // Prime the asset load so `duration` is concrete.
    let duration = try await waitForDuration(source)
    #expect(duration.isValid && !duration.isIndefinite)

    let collector = FrameCollector()
    let collectTask = Task {
        for await frame in source.frames {
            await collector.append(frame)
        }
    }
    defer { collectTask.cancel() }

    let beyond = CMTimeAdd(duration, CMTime(seconds: 5.0, preferredTimescale: 600))
    try await source.seek(to: beyond)
    try await Task.sleep(nanoseconds: 50_000_000)

    // `currentTime()` should sit at `duration` after the clamp. AVF may
    // round slightly; tolerance is the same frame-duration × 1.5 budget.
    let currentTime = source.testHooks.playerItem.currentTime()
    let delta = abs(currentTime.seconds - duration.seconds)
    #expect(
        delta <= fixtureSeekToleranceSeconds,
        "past-EOF seek did not clamp to duration (\(duration.seconds)) — currentTime is \(currentTime.seconds)"
    )

    await source.invalidate()
}

/// `step(by: 1)` from `.idle` (paused-on-load, never `play()`'d) yields the
/// frame at frame-index-1 of the clip.
@Test
func stepByOneFromIdleYieldsNextFrame() async throws {
    let url = try fixtureURL()
    let source = PlaybackSource(url: url, driver: ManualTickDriver())

    // Confirm we are in `.idle` — never called `play()`.
    let initialState = await source.state
    #expect(initialState == .idle, "expected initial state .idle, got \(initialState)")

    let collector = FrameCollector()
    let collectTask = Task {
        for await frame in source.frames {
            await collector.append(frame)
        }
    }
    defer { collectTask.cancel() }

    try await source.step(by: 1)
    try await Task.sleep(nanoseconds: 50_000_000)

    let frame = try #require(
        await collector.last(),
        "step(by: 1) from .idle yielded no frame"
    )
    // Expect frame timestamp ≈ 1/30s (one frame past .zero). AVF may land
    // on the first sample at .zero or the one at 1/30s — both are
    // acceptable "stepped past the start" outcomes; assert simply that
    // the frame is within one frame of 1/30s.
    let expected = fixtureFrameDuration
    let delta = abs(frame.seconds - expected)
    #expect(
        delta <= fixtureSeekToleranceSeconds,
        "step(by: 1) yielded frame at \(frame.seconds); expected ≈ \(expected)"
    )

    // State must not have changed — `step` doesn't transition out of `.idle`.
    let afterState = await source.state
    #expect(afterState == .idle, "step changed state to \(afterState)")

    await source.invalidate()
}

/// `step(by: -1)` at `.zero` is a no-op — graceful, no crash, no error.
@Test
func stepBackwardAtZeroIsGracefulNoOp() async throws {
    let url = try fixtureURL()
    let source = PlaybackSource(url: url, driver: ManualTickDriver())

    let collector = FrameCollector()
    let collectTask = Task {
        for await frame in source.frames {
            await collector.append(frame)
        }
    }
    defer { collectTask.cancel() }

    // No throw, no crash.
    try await source.step(by: -1)
    try await Task.sleep(nanoseconds: 50_000_000)

    // currentTime should still be at .zero (or very close).
    let currentTime = source.testHooks.playerItem.currentTime()
    #expect(
        currentTime.seconds <= fixtureSeekToleranceSeconds,
        "step(-1) at .zero advanced time to \(currentTime.seconds)"
    )

    // State unchanged.
    let state = await source.state
    #expect(state == .idle, "step(-1) changed state to \(state)")

    await source.invalidate()
}

/// `step(by: N)` past EOF clamps gracefully — no crash, no error. AVF's
/// internal step-clamp leaves `currentTime` at-or-near `duration`.
@Test
func stepPastEOFClampsGracefully() async throws {
    let url = try fixtureURL()
    let source = PlaybackSource(url: url, driver: ManualTickDriver())

    let duration = try await waitForDuration(source)
    #expect(duration.isValid && !duration.isIndefinite)

    let collector = FrameCollector()
    let collectTask = Task {
        for await frame in source.frames {
            await collector.append(frame)
        }
    }
    defer { collectTask.cancel() }

    // Step way past the end. The clip is ~9.47s @ 30fps ≈ 284 frames;
    // step by 10_000 is firmly past EOF.
    try await source.step(by: 10_000)
    try await Task.sleep(nanoseconds: 50_000_000)

    let currentTime = source.testHooks.playerItem.currentTime()
    #expect(
        currentTime.seconds <= duration.seconds + fixtureSeekToleranceSeconds,
        "step past EOF left currentTime beyond duration: \(currentTime.seconds) > \(duration.seconds)"
    )

    await source.invalidate()
}

/// Mid-`play()` `seek` does not finish the `frames` stream. The stream
/// continues producing frames after the seek without restart.
@Test
func midPlaySeekDoesNotFinishStream() async throws {
    let url = try fixtureURL()
    // Real `TaskTickDriver` so `play()` produces frames as normal.
    let source = PlaybackSource(url: url, driver: TaskTickDriver(hz: 60))

    try await source.start()

    // Pull a handful of pre-seek frames so we know the stream is live.
    var preSeekCount = 0
    var iterator = source.frames.makeAsyncIterator()
    while preSeekCount < 3 {
        if await iterator.next() == nil {
            Issue.record("stream finished before pre-seek frames arrived")
            return
        }
        preSeekCount += 1
    }

    // Seek mid-clip while play is active.
    let target = CMTime(seconds: 4.0, preferredTimescale: 600)
    try await source.seek(to: target)

    // Stream must continue — pull post-seek frames. If `seek` had
    // finished the continuation, `.next()` would return `nil` here.
    var postSeekCount = 0
    let deadline = ContinuousClock().now + .seconds(5)
    while postSeekCount < 3, ContinuousClock().now < deadline {
        if await iterator.next() == nil {
            Issue.record("frames stream finished after mid-play seek")
            break
        }
        postSeekCount += 1
    }
    #expect(
        postSeekCount >= 3,
        "post-seek stream produced only \(postSeekCount) frames"
    )

    await source.invalidate()
}
