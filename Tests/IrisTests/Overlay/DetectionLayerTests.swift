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
            videoRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            style: .default,
            displayTimeSource: { .zero }
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
            style: .default,
            stalenessThreshold: CMTime(value: 2, timescale: 1),
            displayTimeSource: { .zero }
        )

        let host = HostView { layer }
        #expect(type(of: host.body) != Never.self)
    }

    @Test
    func applyFilterPassesThroughWhenNil() {
        // No filter → input array returned unchanged. This is the
        // pre-M4 default behavior — every cached detection at the
        // looked-up timestamp is drawn.
        let detections = [
            Detection(
                boundingBox: CGRect(x: 0, y: 0, width: 0.2, height: 0.2),
                label: "lo",
                confidence: 0.2,
                sourceModelID: "detection-layer-tests"
            ),
            Detection(
                boundingBox: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.2),
                label: "hi",
                confidence: 0.9,
                sourceModelID: "detection-layer-tests"
            ),
        ]
        let result = DetectionLayer<PlayerLayerConverter>.applyFilter(nil, to: detections)
        #expect(result.count == 2)
        #expect(result.map(\.label) == ["lo", "hi"])
    }

    @Test
    func applyFilterDropsDetectionsFailingPredicate() {
        // M4 polish: the body's draw-time filter pass is the symptom
        // fix for "filter-tier slider changes are invisible while
        // paused." `DetectorPipeline` only applies `tuning.filter` when
        // frames flow; with the source paused, the overlay reads
        // `ResultStore` directly. This helper is the per-tick filter
        // application the body uses — exercising it directly covers
        // the symptom without rendering a Canvas.
        let detections = [
            Detection(
                boundingBox: CGRect(x: 0, y: 0, width: 0.2, height: 0.2),
                label: "lo",
                confidence: 0.2,
                sourceModelID: "detection-layer-tests"
            ),
            Detection(
                boundingBox: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.2),
                label: "hi",
                confidence: 0.9,
                sourceModelID: "detection-layer-tests"
            ),
        ]
        let predicate: @Sendable (Detection) -> Bool = { $0.confidence >= 0.5 }
        let result = DetectionLayer<PlayerLayerConverter>.applyFilter(
            predicate,
            to: detections
        )
        #expect(result.map(\.label) == ["hi"])
    }

    @Test
    func tuningParameterFlowsThroughInit() {
        // The `tuning:` parameter must be nil-defaultable (preserves
        // pre-M4 call sites) and accept any `TuningRouter` (the
        // protocol-erased shape `TuningModel` conforms to).
        let store = ResultStore()
        let detector = VisionRectanglesDetector()
        let model = TuningModel(detector: detector)
        let layer = DetectionLayer(
            store: store,
            converter: PlayerLayerConverter(),
            videoRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            style: .default,
            stalenessThreshold: nil,
            tuning: model,
            displayTimeSource: { .zero }
        )
        let host = HostView { layer }
        #expect(type(of: host.body) != Never.self)
    }

    @Test
    func customStyleAndDisplayTimeSourceCompose() {
        // The M3 playback override path — `displayTimeSource` closure captures
        // a CMTime from the call site. Smoke that both the custom style and
        // the custom displayTimeSource flow through the init together.
        let store = ResultStore()
        let frozen = CMTime(value: 42, timescale: 60)
        let style = OverlayStyle(strokeWidth: 3.0, labelTextColor: .yellow)
        let layer = DetectionLayer(
            store: store,
            converter: PlayerLayerConverter(),
            videoRect: CGRect(x: 0, y: 0, width: 200, height: 200),
            style: style,
            displayTimeSource: { frozen }
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
