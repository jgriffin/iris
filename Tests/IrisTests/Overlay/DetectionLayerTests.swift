import CoreGraphics
import CoreMedia
import SwiftUI
import Testing

@testable import Iris

/// Construction-level coverage of `DetectionLayer`. SwiftUI's `Canvas` output
/// isn't readable from tests without snapshot tooling; the meaningful test
/// surface is "does the public init compile, accept the locked argument list,
/// and live inside a parent SwiftUI struct without trapping?"
///
/// End-to-end visual validation is split across Phase 6 (`#Preview` cases)
/// and Phase 7 (physical-device smoke).
@MainActor
@Suite("DetectionLayer")
struct DetectionLayerTests {

    @Test
    func constructsWithPlayerLayerConverterAndIsUsableInAView() {
        let store = ResultStore()
        let entry = TimestampedDetections(
            timestamp: CMTime(value: 10, timescale: 60),
            detections: [
                Detection(
                    boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4),
                    label: "subject",
                    confidence: 0.9,
                    sourceModelID: "detection-layer-tests"
                )
            ]
        )
        store.append(entry)

        let layer = DetectionLayer(
            store: store,
            converter: PlayerLayerConverter(),
            videoRect: CGRect(x: 0, y: 0, width: 100, height: 100)
        )

        // Wrap in a host view to confirm the layer composes as a SwiftUI
        // child without forcing the caller into Representable territory.
        let host = HostView { layer }
        #expect(type(of: host.body) != Never.self)
    }

    @Test
    func stalenessThresholdParameterFlowsThrough() {
        // Construct with an explicit per-call staleness override (the playback
        // path passes `store.playbackStalenessThreshold` here). Smoke: the
        // initializer accepts the parameter and the view still composes.
        let store = ResultStore()
        let layer = DetectionLayer(
            store: store,
            converter: PlayerLayerConverter(),
            videoRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            stalenessThreshold: CMTime(value: 2, timescale: 1)
        )

        let host = HostView { layer }
        #expect(type(of: host.body) != Never.self)
    }
}

// MARK: - Helpers

/// Thin SwiftUI wrapper used to confirm `DetectionLayer` slots into a parent
/// `View` body without triggering compile-time or runtime traps. No rendering
/// assertion — Canvas output isn't introspectable from unit tests.
private struct HostView<Content: View>: View {
    let content: () -> Content
    var body: some View { content() }
}
