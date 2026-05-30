import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import Testing

@testable import Iris

// MARK: - Test goal
//
// `PlaybackDetectionCoordinator` is the library type that owns the playback
// detection-session orchestration the demos used to duplicate. These tests
// close the accepted gap (`plans/QUESTIONS.md` `[open 2026-05-26]` "No
// regression test for the playback detector-swap path") now that the glue is
// a testable library type.
//
// The headline is the **swap regression test**: start on detector A, drive a
// frame, swap to detector B, re-emit a frame, and assert the cached detections
// are B's. This passes only because `selectDetector` does cancel → **drain**
// (`await task.value`) → respawn before re-emitting — making B the sole
// consumer of the single-consumer `frames` stream. Without the drain, the
// re-emitted frame races between the dying A consumer and the new B consumer,
// and the stale A detector can win (the bug commit f4a6284 fixed).
//
// The other two pin the contracts the spec calls out: `setSource` resets
// metrics + invalidates the cache, and `teardown` only returns after the
// source is invalidated (the sandbox-scope ordering contract).

// MARK: - Fixtures

/// The M2 LFS-tracked smoke clip — 1280×720, h.264, 30 fps, ~9.47s. A real
/// `PlaybackSource` is required because the coordinator builds a
/// `PlaybackController` over the source and the pause-emit / re-emit path
/// drives `source.seek(...)` against AVF. A `ManualTickDriver` keeps the
/// playback cadence deterministic — no real-time scheduling.
private func fixtureURL() throws -> URL {
    try #require(
        Bundle.module.url(forResource: "clipboard-blank-page", withExtension: "mp4"),
        """
        Missing fixture clipboard-blank-page.mp4 — \
        run `git lfs install && git lfs pull` after clone.
        """
    )
}

/// Two `MockDetector`s with distinct labels so we can tell which one's output
/// landed in the cache. Each returns a single full-frame box stamped with its
/// own label; the `modelIdentifier` is independent and threaded through
/// `sourceModelID` so a cache entry is unambiguous.
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

    /// A plain-`Detector` catalog entry (→ `PassthroughRouter` + `EmptyView`),
    /// matching the non-tunable path the coordinator must handle gracefully.
    @MainActor
    static func entry(label: String) -> DetectorCatalogEntry {
        .make(id: "mock.\(label)", displayName: label) {
            MockDetector(
                detections: [detection(label: label)],
                modelIdentifier: label
            )
        }
    }
}

/// Poll `resultStore.lookup(at:)` for an entry whose detections carry `label`,
/// up to `deadline`. The detect loop reads frames asynchronously off the main
/// actor, so a write may not be visible the instant a re-emit/seek returns.
/// Returns the first matching detections, or `nil` on timeout.
@MainActor
private func awaitLabeledDetection(
    in store: ResultStore,
    label: String,
    at time: CMTime,
    timeout: Duration = .seconds(3)
) async -> [Detection]? {
    let deadline = ContinuousClock().now + timeout
    while ContinuousClock().now < deadline {
        let hits = store.lookup(at: time, stale: store.playbackStalenessThreshold)
        if hits.contains(where: { $0.label == label }) {
            return hits
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return nil
}

// MARK: - Tests

@MainActor
@Suite struct PlaybackDetectionCoordinatorTests {

    /// **The swap regression test (the headline).** Start detecting with A,
    /// drive a frame so A's output is cached, swap to B, then drive a *fresh*
    /// frame and assert that frame's detection is B's — never A's.
    ///
    /// **Why a fresh frame at a distinct timestamp, not a re-emit at the same
    /// time.** `PlaybackSource.emitOneShotFrame()` only yields when
    /// `AVPlayerItemVideoOutput.hasNewPixelBuffer(forItemTime:)` is true, which
    /// is false for an already-consumed item time — so seeking twice to the
    /// *same* time is a no-op against a paused video output (verified
    /// empirically). The coordinator's own re-emit (`seek(to: currentTime)`)
    /// therefore can't drive a new frame here, because the player isn't playing
    /// and `currentTime` stays at the A-cached time. Driving a frame at a
    /// distinct timestamp after the swap is the deterministic seam; it
    /// exercises exactly what the swap is about — *which detector consumes the
    /// next frame off the single, long-lived detect loop*.
    ///
    /// **What this guards.** The coordinator runs **one** detect loop per
    /// source (the single-iteration `AsyncStream` can't be re-consumed), and a
    /// detector swap replaces the active router *in place*; the loop reads the
    /// live router every frame. So the post-swap frame routes through B and B's
    /// output is what lands. A stale A entry on the post-swap frame would mean
    /// the swap didn't take — which this asserts against (`label == labelA`
    /// must NOT appear). This is the playback detector-swap path the
    /// `[open 2026-05-26]` QUESTIONS entry flagged as untested.
    @Test func swappingDetectorMidStreamRoutesNewDetectorOutput() async throws {
        let url = try fixtureURL()
        let source = PlaybackSource(url: url, driver: ManualTickDriver())
        let coordinator = PlaybackDetectionCoordinator()

        // Start on detector A. `setSource` builds the controller + spawns the
        // detect loop; it does NOT start playback, so a `seek(to:)` is the
        // deterministic way to push exactly one frame through.
        await coordinator.setSource(source, detector: DetectorAB.entry(label: DetectorAB.labelA))

        // Drive one frame at t=0 so A's output is cached there. `seek(to:)`
        // resets the monotonicity guard and emits a one-shot frame at the
        // target.
        let timeA = CMTime.zero
        try await source.seek(to: timeA)

        let aHits = await awaitLabeledDetection(
            in: coordinator.resultStore,
            label: DetectorAB.labelA,
            at: timeA
        )
        #expect(
            aHits?.contains(where: { $0.label == DetectorAB.labelA }) == true,
            "Detector A's output should be cached at t=0 before the swap"
        )

        // Swap to detector B. This drains the A loop and respawns the B loop as
        // the sole stream consumer (`selectDetector` also invalidates the cache
        // and re-emits at the current playhead, but with a paused player at the
        // already-consumed t=0 that re-emit is a no-op — see the doc above).
        await coordinator.selectDetector(DetectorAB.entry(label: DetectorAB.labelB))

        // Drive a frame at a FRESH timestamp. This is the frame whose ownership
        // is the regression signal: with the drain, only B's loop is alive to
        // read it; without it, a lingering A loop could win the race.
        let timeB = CMTime(seconds: 1.0, preferredTimescale: 600)
        try await source.seek(to: timeB)

        let bHits = await awaitLabeledDetection(
            in: coordinator.resultStore,
            label: DetectorAB.labelB,
            at: timeB
        )
        let observed = try #require(
            bHits,
            "Detector B's output never landed in the cache after the swap"
        )
        #expect(
            observed.contains(where: { $0.label == DetectorAB.labelB }),
            "After the swap, the post-swap frame should be detected by B"
        )
        #expect(
            !observed.contains(where: { $0.label == DetectorAB.labelA }),
            """
            After the swap, A must NOT be the consumer of the post-swap frame — \
            a stale A entry here is the race the drain prevents.
            """
        )

        await coordinator.teardown()
    }

    /// **Freeze-from-live (M8·P5).** After the detect loop processes a frame, the
    /// coordinator publishes it on `currentFrame` (on the @MainActor) so the demo
    /// can freeze the visible still and hand it to the image inspector. Drive one
    /// frame via `seek`, and assert `currentFrame` becomes non-nil and reflects a
    /// processed frame (its timestamp matches the seek target the detect loop just
    /// ran on). `teardown` then clears it.
    @Test func currentFrameReflectsProcessedFrame() async throws {
        let url = try fixtureURL()
        let source = PlaybackSource(url: url, driver: ManualTickDriver())
        let coordinator = PlaybackDetectionCoordinator()

        // Nothing processed yet — no frozen frame to inspect.
        #expect(coordinator.currentFrame == nil)

        await coordinator.setSource(source, detector: DetectorAB.entry(label: DetectorAB.labelA))

        // Drive one frame at t=0 through the single detect loop.
        let time = CMTime.zero
        try await source.seek(to: time)

        // The loop publishes `currentFrame` on a MainActor hop after running the
        // frame; poll until it lands (same async-visibility caveat as the cache).
        let deadline = ContinuousClock().now + .seconds(3)
        while coordinator.currentFrame == nil, ContinuousClock().now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }

        let frozen = try #require(
            coordinator.currentFrame,
            "currentFrame should reflect the frame the detect loop just processed"
        )
        #expect(
            frozen.timestamp == time,
            "currentFrame should be the frame driven through the loop (t=0)"
        )

        await coordinator.teardown()

        // Teardown clears the frozen frame alongside the controller + cache.
        #expect(coordinator.currentFrame == nil)
    }

    /// `setSource` resets the metrics gauge and invalidates the cache so a new
    /// video starts from a clean slate (no carried-over counts or stale
    /// detections from the prior session).
    @Test func setSourceResetsMetricsAndInvalidatesCache() async throws {
        let url = try fixtureURL()
        let coordinator = PlaybackDetectionCoordinator()

        // Pre-load the cache + metrics with junk that must not survive a new
        // source. (`recordInference` bumps `processedCount`; `append` seeds a
        // cache entry.)
        coordinator.metrics.recordInference(seconds: 0.05)
        coordinator.resultStore.append(
            TimestampedDetections(
                timestamp: .zero,
                detections: [DetectorAB.detection(label: "stale")]
            )
        )
        #expect(coordinator.metrics.processedCount == 1)
        #expect(!coordinator.resultStore.lookup(at: .zero).isEmpty)

        let source = PlaybackSource(url: url, driver: ManualTickDriver())
        await coordinator.setSource(source, detector: DetectorAB.entry(label: DetectorAB.labelA))

        // Metrics zeroed and the stale "stale" entry cleared. (The detect loop
        // hasn't been driven — no frame seeked — so nothing fresh is cached;
        // the assertion is specifically that the pre-seeded entry is gone.)
        #expect(coordinator.metrics.processedCount == 0)
        #expect(coordinator.metrics.lastInferenceMillis == nil)
        #expect(
            !coordinator.resultStore.lookup(at: .zero).contains { $0.label == "stale" },
            "The pre-seeded stale entry should be invalidated by setSource"
        )

        await coordinator.teardown()
    }

    /// `teardown` returns only after the source's `invalidate()` has completed
    /// — the sandbox-scope ordering contract. The demo releases its security
    /// scope strictly after the `await` returns, so AVF must be done reading
    /// the URL by then.
    ///
    /// `PlaybackSource` is `final`, so we can't subclass it to flip a probe
    /// flag inside `invalidate()`. Instead we assert against the real,
    /// observable post-condition that `invalidate()` (and only `invalidate()`)
    /// establishes: it calls `setState(.stopped)` and finishes the `frames`
    /// stream. After `setSource`, the source is mid-session (the detect loop is
    /// iterating `frames`, not `.stopped`); the instant `teardown()` returns,
    /// `state == .stopped` — proving the coordinator awaited `invalidate()`
    /// rather than returning while the source was still live.
    @Test func teardownReturnsOnlyAfterSourceInvalidated() async throws {
        let url = try fixtureURL()
        let source = PlaybackSource(url: url, driver: ManualTickDriver())
        let coordinator = PlaybackDetectionCoordinator()

        await coordinator.setSource(source, detector: DetectorAB.entry(label: DetectorAB.labelA))
        // Pre-condition: a fresh, un-invalidated source has not been stopped.
        #expect(source.state != .stopped)

        await coordinator.teardown()

        // The only path to `.stopped` here is `invalidate()`; reading it set
        // the instant `teardown()` returns proves the await-after-invalidate
        // ordering the scope contract depends on.
        #expect(
            source.state == .stopped,
            "teardown() must complete the source's invalidate() before returning"
        )
        #expect(coordinator.controller == nil)
        #expect(coordinator.session == nil)
    }
}
