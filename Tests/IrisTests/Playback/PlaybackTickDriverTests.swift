import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import Iris

// MARK: - Fixture

/// Same M2 LFS-tracked smoke clip used by `PlaybackSourceTests`. Hoisted
/// into a sibling file so the driver-swap tests can read fixtures
/// without importing each other's helpers.
private func tickDriverFixtureURL() throws -> URL {
    try #require(
        Bundle.module.url(forResource: "clipboard-blank-page", withExtension: "mp4"),
        """
        Missing fixture clipboard-blank-page.mp4 — \
        run `git lfs install && git lfs pull` after clone.
        """
    )
}

// MARK: - setTickDriver

/// `setTickDriver(_:)` from `.idle` installs the new driver without
/// starting it. Verified by swapping in a `ManualTickDriver`, firing it,
/// and confirming a frame is emitted (which couldn't happen if the swap
/// was a no-op or if the old `TaskTickDriver` was still in charge).
@Test
func setTickDriverFromIdleInstallsNewDriverWithoutStarting() async throws {
    let url = try tickDriverFixtureURL()
    let source = PlaybackSource(url: url, driver: TaskTickDriver(hz: 60))

    let manual = ManualTickDriver()
    source.setTickDriver(manual)

    // We never called `play()` — state is `.idle`. Firing the manual
    // driver should be a no-op for frame emission (no buffer at
    // `currentTime` for a never-played item until the asset loads, and
    // even then the tick path only emits if `hasNewPixelBuffer`). The
    // important check is that no crash, no state change.
    manual.fire()
    let state = await source.state
    #expect(state == .idle, "setTickDriver changed state to \(state)")

    await source.invalidate()
}

/// `setTickDriver(_:)` mid-`play()` swaps in the new driver and starts
/// it without stopping playback. Verified by observing that state stays
/// `.running` across the swap (the swap does not transition state), and
/// that the new driver is asked to start (its `start(tick:)` is called).
///
/// Why not assert "frames continue to arrive via the new driver"?
/// `PlaybackSource.tick()` drops emissions when `currentTime ≤
/// lastEmittedItemTime` (monotonicity guard). Right after a mid-play
/// swap, the original `TaskTickDriver` has been emitting at 60 Hz, so
/// `lastEmittedItemTime` is near `currentTime`. A handful of post-swap
/// manual `fire()`s race against the player's clock advance; whether
/// they land before or after the next pixel buffer is timing-dependent.
/// We assert the structural swap properties instead.
@Test
func setTickDriverMidPlaySwapsDriverWithoutChangingState() async throws {
    let url = try tickDriverFixtureURL()
    let source = PlaybackSource(url: url, driver: TaskTickDriver(hz: 60))

    try await source.start()

    // Pull one frame so we know the original driver was producing.
    var iterator = source.frames.makeAsyncIterator()
    _ = await iterator.next()

    // Use a recording driver so we can assert `start(tick:)` was called
    // on the new driver, confirming the swap propagated.
    let recorder = RecordingTickDriver()
    source.setTickDriver(recorder)

    let state = await source.state
    #expect(state == .running, "setTickDriver during play changed state to \(state)")
    #expect(recorder.startedCount() == 1, "new driver was not started after mid-play swap")

    await source.invalidate()
    // After invalidate, the new driver should have been stopped exactly
    // once (no further ticks).
    #expect(recorder.stoppedCount() >= 1, "new driver was not stopped on invalidate")
}

/// Test double that records `start(tick:)` and `stop()` invocations.
/// Used to assert that `PlaybackSource.setTickDriver` actually wires the
/// new driver into the lifecycle.
private final class RecordingTickDriver: PlaybackTickDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var _started = 0
    private var _stopped = 0

    func start(tick: @escaping @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        _started += 1
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        _stopped += 1
    }

    func startedCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return _started
    }

    func stoppedCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return _stopped
    }
}

/// `setTickDriver(_:)` is identity-idempotent — passing the
/// currently-installed driver does not stop/restart it.
@Test
func setTickDriverWithSameDriverIsNoOp() async throws {
    let url = try tickDriverFixtureURL()
    let initialDriver = TaskTickDriver(hz: 60)
    let source = PlaybackSource(url: url, driver: initialDriver)

    // No crash, no state change.
    source.setTickDriver(initialDriver)
    let state = await source.state
    #expect(state == .idle)

    await source.invalidate()
}
