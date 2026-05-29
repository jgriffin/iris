import CoreMedia
import Foundation

/// The narrow seam ``FlaggingModel`` depends on: the playhead position, the
/// detections visible at that position, and a fire-and-forget seek.
///
/// **Why a protocol rather than the coordinator directly.** Flagging only
/// needs three things from the playback world — *where is the playhead*,
/// *what is on screen there*, and *jump there*. Depending on the full
/// [`PlaybackDetectionCoordinator`](../Playback/PlaybackDetectionCoordinator.swift)
/// would couple the dataset layer to the detect-loop, metrics, session, and
/// security-scope machinery it has no business knowing. The protocol keeps
/// the model testable (a mock conformer needs only a stored `currentPTS`,
/// canned detections, and a recorded seek target) and decoupled (the
/// coordinator conforms in an extension; the model never names it).
///
/// **`@MainActor` + `AnyObject`.** The model holds the source as an
/// `unowned` reference (the coordinator owns the model's lifetime in the
/// demo, so a strong reference would cycle); class-bound is required for an
/// unowned reference, and `@MainActor` matches the coordinator's isolation
/// so reads need no hop.
@MainActor
public protocol FlaggingSource: AnyObject {

    /// Current playhead position, or `nil` when no source is active. This is
    /// the canonical address component for a flag — the model pairs it with
    /// the asset fingerprint to build a ``FrameRef``.
    var currentPTS: CMTime? { get }

    /// Model-predicted detections visible at the current playhead. Captured
    /// into a ``FrameFlag`` as provisional annotations at flag time.
    func currentDetections() -> [Detection]

    /// Jump to `pts`. **Fire-and-forget** — the underlying seek is async and
    /// throwing, but a flagging UI tap can't await; conformers wrap it in a
    /// `Task` and swallow errors (a failed jump is a no-op, not a crash).
    func seek(to pts: CMTime)
}
