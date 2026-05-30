import Iris
import Observation
import SwiftUI

/// Demo-side "freeze-from-live" conduit (M8·P5): carries a frozen `Frame` from a
/// live source (playback overlay, iOS capture overlay) to the Image page's
/// `ImageDetectionCoordinator`, which re-runs detectors on that still.
///
/// **Why a conduit on iOS.** The iOS demo's source pages (Playback, Capture) and
/// the Image page live in *separate* tabs with separate `@State`; they can't hand
/// a frame to each other directly. This tiny `@Observable` lives at the root,
/// injected via `.environment`, so a source page can post an `InspectRequest` and
/// the Image page can observe it. (macOS holds both coordinators in one view, so
/// it inspects directly — no conduit needed.)
///
/// **Interim.** This is throwaway nav glue; the planned unified-sidebar pass
/// subsumes it (a single shell holding all sources can wire freeze-from-live
/// without an environment hop). Kept deliberately minimal.
@MainActor
@Observable
final class InspectorHandoff {

    /// The pending inspect request, or `nil` once consumed. The Image page reads
    /// it, runs `setImage`, then clears it back to `nil`.
    var request: InspectRequest?

    /// Monotonic token so repeated inspects — even of the *same* `Frame` — bump
    /// `request` to a value SwiftUI sees as changed (`Frame` isn't `Equatable`;
    /// `InspectRequest` compares on `token` alone). Downstream observers key off
    /// `request?.token`.
    private var nextToken = 0

    /// Post a freeze-from-live request: hold `frame` to inspect under the
    /// detector identified by `detectorID` (the live source's current detector,
    /// so the still opens on the same model before the user can swap).
    func inspect(_ frame: Frame, detectorID: String) {
        nextToken += 1
        request = InspectRequest(frame: frame, detectorID: detectorID, token: nextToken)
    }
}

/// A single freeze-from-live request. `Frame` isn't `Equatable`, so equality is
/// defined on the monotonic `token` alone — enough for SwiftUI change-observation
/// (`.onChange` / `.task(id:)`), and it makes a re-inspect of the same frame
/// register as a new request.
struct InspectRequest: Equatable {
    let frame: Frame
    let detectorID: String
    let token: Int

    static func == (lhs: InspectRequest, rhs: InspectRequest) -> Bool {
        lhs.token == rhs.token
    }
}
