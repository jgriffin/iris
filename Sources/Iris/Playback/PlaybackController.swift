@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Observation
import os

// MARK: - PlaybackController

/// `@MainActor @Observable` SwiftUI-facing layer over a
/// [`PlaybackSource`](./PlaybackSource.swift). Mirrors the
/// [`ResultStore`](../Overlay/ResultStore.swift) doctrine — a sibling
/// observable wrapper, not a remodel of the underlying source.
///
/// **Why a sibling, not making `PlaybackSource` itself `@Observable`.**
/// `PlaybackSource` is `@unchecked Sendable` with `NSLock`-guarded state
/// because its tick driver invokes `tick()` from off-MainActor contexts
/// (`TaskTickDriver` runs on a detached `Task`, `DisplayLinkTickDriver`
/// runs on the display-link callback). Lifting the source to `@MainActor`
/// would require the tick path to hop into MainActor on every frame —
/// pure overhead that breaks the "no per-frame `Task` spawn" decision in
/// [`plans/DECISIONS.md`](../../../plans/DECISIONS.md) §"Runtime frame
/// pipeline". A sibling controller keeps the source's threading model
/// intact while giving SwiftUI views the observable bindings they need.
///
/// **Observation sources.**
/// - `currentTime`: `AVPlayer.addPeriodicTimeObserver` at ~30 Hz. The
///   callback fires on the main queue, so the property write stays
///   on-MainActor without a re-hop.
/// - `state`: forwarded from `PlaybackSource.state`. Refreshed on every
///   `togglePlay` / `seek` / `step` call and on `play()` / `pause()`
///   completion. The source already handles the canonical state
///   transitions; the controller mirrors them rather than re-deriving.
/// - `duration`: KVO on `AVPlayerItem.duration`. Becomes valid after
///   `.readyToPlay`; the slider treats `.indefinite` / `.invalid` as
///   "no track yet".
///
/// **`Scrubber` is wired against `ScrubberModel`, not this class.** That
/// keeps the preview path AVF-free; this is the production conformer.
@MainActor
@Observable
public final class PlaybackController: ScrubberModel {

    // MARK: - Observable state

    /// Playhead position, updated from the periodic time observer.
    public private(set) var currentTime: CMTime = .zero

    /// Asset duration, updated when the player item becomes
    /// `.readyToPlay`. `.invalid` until the asset loads.
    public private(set) var duration: CMTime = .invalid

    /// Mirror of `source.state`. Set explicitly after each control action
    /// so the UI ticks on the same edge.
    public private(set) var state: SourceState = .idle

    // MARK: - Stored

    /// The wrapped source. Public so callers that also need the AVF-side
    /// seam (e.g. `DetectionLayer.displayTimeSource: { source.player.currentTime() }`)
    /// can reach it.
    public let source: PlaybackSource

    private let player: AVPlayer
    private let playerItem: AVPlayerItem
    /// `nonisolated(unsafe)` because `deinit` must read these to tear
    /// down the observers, and Swift 6's `deinit` is nonisolated even
    /// on a `@MainActor`-isolated class. `@ObservationIgnored` keeps
    /// the `@Observable` macro from re-expanding them — these aren't
    /// SwiftUI-observable state, just bookkeeping handles. Writes only
    /// happen during `init` (still on MainActor), so there's no
    /// concurrent-mutation risk.
    @ObservationIgnored private nonisolated(unsafe) var timeObserverToken: Any?
    @ObservationIgnored private nonisolated(unsafe) var durationObservation: NSKeyValueObservation?
    @ObservationIgnored private nonisolated(unsafe) var statusObservation: NSKeyValueObservation?
    private let logger = Logger(subsystem: "iris.playback", category: "controller")

    // MARK: - Init

    /// Build a controller for `source`. Wires the periodic time observer
    /// and KVO on the underlying `AVPlayerItem` immediately, so binding a
    /// `Scrubber` against `self` doesn't require an explicit "start
    /// observing" step.
    public init(source: PlaybackSource) {
        self.source = source
        self.player = source.playerForPreview
        // Reading the player item off the source is fine here — the
        // controller owns its observation lifecycle and the source's
        // documented invariant is that `player` / `playerItem` are
        // immutable after `init`.
        self.playerItem = source.testHooks.playerItem
        self.state = source.state

        installTimeObserver()
        installDurationObservation()
        installStatusObservation()
    }

    deinit {
        // Tear-down can run on a non-MainActor thread (Swift 6's deinit
        // is nonisolated). The `removeTimeObserver` and KVO-invalidate
        // calls are documented thread-safe on AVF / Foundation, so it's
        // safe to call them here without hopping to MainActor.
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
        }
        durationObservation?.invalidate()
        statusObservation?.invalidate()
    }

    // MARK: - ScrubberModel actions

    /// Play if paused, pause if running. Bridges to the source's async
    /// `play()` / `pause()` via a structured `Task` — the call site
    /// (`Scrubber`'s play/pause button) is a sync SwiftUI action closure.
    public func togglePlay() {
        switch source.state {
        case .failed:
            return
        case .running:
            Task { [source] in
                await source.pause()
                await MainActor.run { self.state = source.state }
            }
        default:
            Task { [source] in
                do {
                    try await source.play()
                } catch {
                    self.logger.error(
                        "play() failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
                await MainActor.run { self.state = source.state }
            }
        }
    }

    /// Frame-accurate seek. Drag-handlers in SwiftUI call this many times
    /// per drag; the source's `seek(to:)` already serializes against AVF's
    /// async seek completion, so back-to-back invocations queue up cleanly
    /// without the controller needing its own debounce.
    public func seek(to time: CMTime) {
        Task { [source] in
            do {
                try await source.seek(to: time)
            } catch {
                self.logger.error(
                    "seek failed: \(error.localizedDescription, privacy: .public)"
                )
            }
            await MainActor.run { self.state = source.state }
        }
    }

    /// Step ±`count` frames via `AVPlayerItem.step(byCount:)`. No-op at
    /// asset boundaries (AVF clamps internally).
    public func step(by count: Int) {
        Task { [source] in
            do {
                try await source.step(by: count)
            } catch {
                self.logger.error(
                    "step failed: \(error.localizedDescription, privacy: .public)"
                )
            }
            await MainActor.run { self.state = source.state }
        }
    }

    // MARK: - Observation wiring

    /// Install a periodic time observer at ~30 Hz. The interval matches a
    /// typical asset frame rate — finer than that just thrashes the
    /// slider's redraws; coarser feels laggy. The observer fires on the
    /// main queue (`nil` queue parameter uses main), so the property
    /// write stays on-MainActor.
    private func installTimeObserver() {
        let interval = CMTime(value: 1, timescale: 30)
        // `addPeriodicTimeObserver`'s closure is `@Sendable` under AVF's
        // Swift 6 annotations; capture `self` weakly + hop to MainActor
        // for the assignment.
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            // Closure runs on `.main` queue, which is *not* the same as
            // running on `@MainActor` under Swift 6 strict concurrency.
            // Hop explicitly.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time
                // Cheap to refresh — `source.state` is an `NSLock` read,
                // and it lets the UI catch transitions (e.g. EOF →
                // `.stopped`) without a separate observer.
                self.state = self.source.state
            }
        }
    }

    /// KVO on `AVPlayerItem.duration`. The duration becomes valid once
    /// the asset loads (`.readyToPlay`). Slider stays disabled until
    /// then.
    private func installDurationObservation() {
        durationObservation = playerItem.observe(
            \.duration,
            options: [.initial, .new]
        ) { [weak self] item, _ in
            let newDuration = item.duration
            // Same MainActor hop as the time observer — KVO callbacks
            // are not on `@MainActor` even when delivered on `.main`.
            Task { @MainActor [weak self] in
                self?.duration = newDuration
            }
        }
    }

    /// KVO on `AVPlayerItem.status` so the controller's mirror of
    /// `source.state` is updated when the asset transitions to
    /// `.failed`. The periodic time observer also refreshes `state`, but
    /// only fires while the player is producing time — for `.failed`
    /// during load there are no time ticks, so this observer is the
    /// catch.
    private func installStatusObservation() {
        statusObservation = playerItem.observe(
            \.status,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            guard let self else { return }
            let sourceState = self.source.state
            Task { @MainActor [weak self] in
                self?.state = sourceState
            }
        }
    }
}
