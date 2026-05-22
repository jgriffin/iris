import CoreMedia
import Foundation
import Testing

@testable import Iris

// MARK: - MockScrubberModel contract

/// `togglePlay()` toggles between `.idle` and `.running` and records the
/// action. The Scrubber view consumes the same observable state, so this
/// is the protocol-level contract every conformer must satisfy.
@Test
@MainActor
func mockScrubberModelTogglePlayRecordsAndFlipsState() {
    let model = MockScrubberModel(state: .idle)

    model.togglePlay()
    #expect(model.state == .running)
    #expect(model.recordedActions == [.togglePlay])

    model.togglePlay()
    #expect(model.state == .idle)
    #expect(model.recordedActions == [.togglePlay, .togglePlay])
}

/// `togglePlay()` is a no-op when state is `.failed` — Scrubber's button
/// is disabled in that state, but the contract holds even if a test or
/// stray binding fires it. Mirrors `PlaybackController.togglePlay()`'s
/// `.failed` short-circuit.
@Test
@MainActor
func mockScrubberModelTogglePlayNoOpInFailedState() {
    let url = URL(fileURLWithPath: "/dev/null")
    let model = MockScrubberModel(state: .failed(.assetLoadFailed(url)))

    model.togglePlay()
    if case .failed = model.state {
        // expected
    } else {
        Issue.record("togglePlay() must not exit .failed state")
    }
}

/// `seek(to:)` clamps to `[.zero, duration]` — matches the
/// `PlaybackSource.seek(to:)` documented behavior. Drag-to-scrub on the
/// slider can pass out-of-range values when the user overshoots, and the
/// model must absorb that silently.
@Test
@MainActor
func mockScrubberModelSeekClampsToAssetBounds() {
    let model = MockScrubberModel(
        currentTime: .zero,
        duration: CMTime(value: 10, timescale: 1),
        state: .idle
    )

    // Seek past end → clamps to duration.
    model.seek(to: CMTime(value: 20, timescale: 1))
    #expect(CMTimeGetSeconds(model.currentTime) == 10)

    // Seek negative → clamps to zero.
    model.seek(to: CMTime(value: -3, timescale: 1))
    #expect(CMTimeGetSeconds(model.currentTime) == 0)

    // In-bounds → exact.
    model.seek(to: CMTime(value: 5, timescale: 1))
    #expect(CMTimeGetSeconds(model.currentTime) == 5)

    // All three seeks recorded in order.
    #expect(model.recordedActions.count == 3)
}

/// `step(by:)` advances `currentTime` and logs a single `.step` action
/// (not an internal `.seek` — the mock pops the synthetic seek to keep
/// the action log meaningful for tests).
@Test
@MainActor
func mockScrubberModelStepRecordsCountAndAdvancesTime() {
    let model = MockScrubberModel(
        currentTime: CMTime(value: 30, timescale: 30),  // 1.0s
        duration: CMTime(value: 10, timescale: 1),
        state: .idle
    )

    model.step(by: 3)  // +3 frames at 30 fps → +0.1s
    #expect(model.recordedActions == [.step(3)])
    // 1.0s + 3/30s = 1.1s. Allow tiny CMTime conversion slop.
    let advanced = CMTimeGetSeconds(model.currentTime)
    #expect(abs(advanced - 1.1) < 1e-9)

    model.step(by: -1)
    #expect(model.recordedActions == [.step(3), .step(-1)])
}
