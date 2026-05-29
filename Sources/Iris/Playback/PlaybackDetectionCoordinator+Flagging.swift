import CoreMedia
import Foundation

// MARK: - FlaggingSource conformance

/// Conform the coordinator to the dataset layer's narrow
/// [`FlaggingSource`](../Dataset/FlaggingSource.swift) seam so a
/// [`FlaggingModel`](../Dataset/FlaggingModel.swift) can read the playhead +
/// visible detections and request jumps without depending on the full
/// coordinator surface.
///
/// The three members map straight onto existing coordinator state:
/// - `currentPTS` → `controller?.currentTime` (`nil` before the first
///   `setSource` / after `teardown`, when `controller` is `nil`).
/// - `currentDetections()` → the same `resultStore.lookup` the overlay reads
///   at the controller's current time, so a flag captures exactly what is on
///   screen. Empty when no controller.
/// - `seek(to:)` → the fire-and-forget wrapper around the source's async
///   throwing seek, identical in shape to the pause-emit hook the coordinator
///   already uses internally.
extension PlaybackDetectionCoordinator: FlaggingSource {

    public var currentPTS: CMTime? {
        controller?.currentTime
    }

    public func currentDetections() -> [Detection] {
        guard let controller else { return [] }
        return resultStore.lookup(
            at: controller.currentTime,
            stale: resultStore.playbackStalenessThreshold
        )
    }

    public func seek(to pts: CMTime) {
        guard let source = controller?.source else { return }
        Task { try? await source.seek(to: pts) }
    }
}
