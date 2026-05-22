import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import Iris

// MARK: - Fixture

/// Same M2 LFS-tracked smoke clip used by `PlaybackSourceTests`. Resolved
/// via `Bundle.module` because `Package.swift` declares
/// `resources: [.process("Fixtures")]` on the test target.
private func controllerFixtureURL() throws -> URL {
    try #require(
        Bundle.module.url(forResource: "clipboard-blank-page", withExtension: "mp4"),
        """
        Missing fixture clipboard-blank-page.mp4 — \
        run `git lfs install && git lfs pull` after clone.
        """
    )
}

// MARK: - Tests

/// On init, the controller mirrors `source.state == .idle` and starts
/// with `.zero` / `.invalid` placeholders. Once the asset loads (via
/// `seek` triggering `ensureReadyToPlay`), `duration` becomes a finite
/// `CMTime` reflecting the asset.
///
/// The KVO + periodic-time-observer wiring runs eagerly in `init`; this
/// test asserts the observable-state surface is consistent before and
/// after asset load.
@Test
@MainActor
func playbackControllerSurfacesDurationAfterAssetLoad() async throws {
    let url = try controllerFixtureURL()
    let source = PlaybackSource(url: url, driver: ManualTickDriver())
    let controller = PlaybackController(source: source)

    // Pre-load state.
    #expect(controller.state == .idle)
    #expect(controller.currentTime == .zero)

    // Force asset load by issuing a seek to .zero — `seek(to:)`
    // gates on `ensureReadyToPlay()`, which polls the player item
    // until `.readyToPlay`. Drives the same code path the scrubber
    // would hit when the user touches the slider.
    try await source.seek(to: .zero)

    // KVO callbacks are dispatched through a `Task { @MainActor }` hop,
    // so give the runloop a few ticks to deliver the observation.
    for _ in 0..<20 {
        if controller.duration.isValid, !controller.duration.isIndefinite,
            CMTimeGetSeconds(controller.duration) > 0
        {
            break
        }
        try await Task.sleep(nanoseconds: 25_000_000)  // 25 ms
    }

    #expect(controller.duration.isValid)
    #expect(!controller.duration.isIndefinite)
    // Fixture is ~9.47s. Use a generous band to absorb keyframe-rounding
    // in CMTime durations across AVF versions.
    let durationSeconds = CMTimeGetSeconds(controller.duration)
    #expect(durationSeconds > 8 && durationSeconds < 11)
}

/// `togglePlay()` from `.idle` transitions the underlying source to
/// `.running`, then back to `.idle` on a second call. The controller's
/// observable `state` mirrors that — the scrubber's icon flip happens
/// off this single property.
@Test
@MainActor
func playbackControllerTogglePlayTransitionsState() async throws {
    let url = try controllerFixtureURL()
    let source = PlaybackSource(url: url, driver: ManualTickDriver())
    let controller = PlaybackController(source: source)

    // Prime the asset so play() doesn't race the load.
    try await source.seek(to: .zero)

    controller.togglePlay()  // → .running
    // The toggle bridges through a `Task`; wait for the state mirror.
    for _ in 0..<40 {
        if case .running = controller.state { break }
        try await Task.sleep(nanoseconds: 25_000_000)
    }
    #expect(controller.state == .running)

    controller.togglePlay()  // → .idle
    for _ in 0..<40 {
        if case .idle = controller.state { break }
        try await Task.sleep(nanoseconds: 25_000_000)
    }
    #expect(controller.state == .idle)

    await source.invalidate()
}
