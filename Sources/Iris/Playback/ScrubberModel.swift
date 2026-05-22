import CoreMedia
import Foundation
import Observation

// MARK: - ScrubberModel

/// The abstraction `Scrubber` depends on — observable playback state plus
/// the four actions a scrub control invokes (`togglePlay`, `seek`, `step`,
/// `replay`).
///
/// **Why a protocol, not a concrete type.** The `#Preview` for `Scrubber`
/// must compose without instantiating any AVF type (per
/// [`plans/features/M3.md`](../../../plans/features/M3.md) §Phase 4 — "no
/// AVF in the preview path"). The production conformer is
/// [`PlaybackController`](./PlaybackController.swift), which wraps an
/// `AVPlayer`; a `MockScrubberModel` (test + preview only) lets the
/// scrubber render under the SwiftUI canvas and exercise its protocol
/// contract without AVF.
///
/// **Observability shape.** Conformers must be `@MainActor`-isolated and
/// `Observable` (the macro-generated tracking that SwiftUI's view body
/// reads). The protocol itself can't carry `@Observable` (Swift macros
/// don't apply to protocols), but every concrete conformer in Iris is
/// declared `@MainActor @Observable final class`.
///
/// **AnyObject constraint.** `Scrubber` stores its model by reference so
/// the same instance can be wired to the surrounding view tree (e.g. a
/// `PlaybackController` also feeds `DetectionLayer.displayTimeSource`).
/// Class-bound also matches the [`ResultStore`](../Overlay/ResultStore.swift)
/// reference-type convention for observable Iris layers.
@MainActor
public protocol ScrubberModel: AnyObject, Observable {

    /// Current playhead position. Drives the slider value. For
    /// [`PlaybackController`](./PlaybackController.swift) this is updated
    /// from `AVPlayer.addPeriodicTimeObserver`.
    var currentTime: CMTime { get }

    /// Total asset duration. Drives the slider's upper bound. May be
    /// `.indefinite` or `.invalid` before the underlying `AVPlayerItem`
    /// reaches `.readyToPlay`; the slider treats those as "no track yet"
    /// and renders a disabled control.
    var duration: CMTime { get }

    /// Mirrors the underlying [`PlaybackSource.state`](./PlaybackSource.swift).
    /// `Scrubber` reads `state == .running` to choose the play-vs-pause
    /// icon and disables step / play when `.failed`.
    var state: SourceState { get }

    /// Play if paused, pause if playing. No-op in `.failed`.
    func togglePlay()

    /// Frame-accurate seek. Forwarded to
    /// [`PlaybackSource.seek(to:)`](./PlaybackSource.swift) — clamps
    /// silently to `[.zero, duration]`. The slider drag handler calls this
    /// on `.onChanged` with the slider's current value converted to
    /// `CMTime`.
    func seek(to time: CMTime)

    /// Step `±count` frames. Forwarded to
    /// [`PlaybackSource.step(by:)`](./PlaybackSource.swift) — no-op at
    /// asset boundaries (AVF clamps internally).
    func step(by count: Int)
}
