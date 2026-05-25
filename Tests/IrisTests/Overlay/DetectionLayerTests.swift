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
    func applyTransformPassesThroughWhenNil() {
        // No transform → input array returned unchanged. This is the
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
        let result = DetectionLayer<PlayerLayerConverter>.applyTransform(
            nil,
            to: detections
        )
        #expect(result.count == 2)
        #expect(result.map(\.label) == ["lo", "hi"])
    }

    @Test
    func applyTransformProjectsDetectionList() {
        // M4 polish: the body's draw-time transform pass is the symptom
        // fix for "filter-tier slider changes are invisible while
        // paused." `DetectorPipeline` only applies `tuning.transform`
        // when frames flow; with the source paused, the overlay reads
        // `ResultStore` directly. This helper is the per-tick
        // transform application the body uses — exercising it directly
        // covers the symptom without rendering a Canvas.
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
        let transform: @Sendable ([Detection]) -> [Detection] = { input in
            input.filter { $0.confidence >= 0.5 }
        }
        let result = DetectionLayer<PlayerLayerConverter>.applyTransform(
            transform,
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

    // MARK: - quadCorners

    @Test
    func quadCornersReturnsCornersInDocumentedOrder() {
        // A detection carrying the four documented corner keypoints yields
        // their positions in topLeft → topRight → bottomRight → bottomLeft
        // order — the order the outline path connects them.
        let tl = CGPoint(x: 0.38, y: 0.82)
        let tr = CGPoint(x: 0.60, y: 0.88)
        let br = CGPoint(x: 0.66, y: 0.66)
        let bl = CGPoint(x: 0.44, y: 0.60)
        let detection = Detection(
            boundingBox: CGRect(x: 0.38, y: 0.60, width: 0.28, height: 0.28),
            label: "tilted",
            confidence: 0.88,
            keypoints: [
                // Deliberately out of corner order to prove the helper
                // resolves by name, not array position.
                Detection.Keypoint(name: "bottomRight", position: br, confidence: 1.0),
                Detection.Keypoint(name: "topLeft", position: tl, confidence: 1.0),
                Detection.Keypoint(name: "bottomLeft", position: bl, confidence: 1.0),
                Detection.Keypoint(name: "topRight", position: tr, confidence: 1.0),
            ],
            sourceModelID: "detection-layer-tests"
        )

        let corners = DetectionLayer<PlayerLayerConverter>.quadCorners(of: detection)
        #expect(corners == [tl, tr, br, bl])
    }

    @Test
    func quadCornersReturnsNilForBoxOnlyDetection() {
        // Box-only detection (keypoints nil) → no quad; caller falls back to
        // the axis-aligned bounding box.
        let detection = Detection(
            boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4),
            label: "box",
            confidence: 0.9,
            sourceModelID: "detection-layer-tests"
        )

        #expect(DetectionLayer<PlayerLayerConverter>.quadCorners(of: detection) == nil)
    }

    @Test
    func quadCornersReturnsNilWhenACornerNameIsMissing() {
        // Keypoints present but missing one of the four corner names →
        // not a quad; fall back to the box.
        let detection = Detection(
            boundingBox: CGRect(x: 0.38, y: 0.60, width: 0.28, height: 0.28),
            label: "partial",
            confidence: 0.88,
            keypoints: [
                Detection.Keypoint(
                    name: "topLeft", position: .init(x: 0.38, y: 0.82), confidence: 1.0),
                Detection.Keypoint(
                    name: "topRight", position: .init(x: 0.60, y: 0.88), confidence: 1.0),
                Detection.Keypoint(
                    name: "bottomRight", position: .init(x: 0.66, y: 0.66), confidence: 1.0),
                // bottomLeft missing.
            ],
            sourceModelID: "detection-layer-tests"
        )

        #expect(DetectionLayer<PlayerLayerConverter>.quadCorners(of: detection) == nil)
    }

    // MARK: - skeletonSegments

    @Test
    func skeletonSegmentsResolvesEdgesByName() {
        // A small synthetic skeleton: three named joints, two edges.
        let neck = CGPoint(x: 0.5, y: 0.8)
        let nose = CGPoint(x: 0.5, y: 0.9)
        let leftShoulder = CGPoint(x: 0.4, y: 0.78)
        let detection = Detection(
            boundingBox: CGRect(x: 0.4, y: 0.78, width: 0.1, height: 0.12),
            label: "person",
            confidence: 0.9,
            keypoints: [
                // Out of order to prove name-resolution, not array order.
                Detection.Keypoint(name: "leftShoulder", position: leftShoulder, confidence: 0.9),
                Detection.Keypoint(name: "nose", position: nose, confidence: 0.9),
                Detection.Keypoint(name: "neck", position: neck, confidence: 0.9),
            ],
            skeleton: Skeleton(edges: [
                Skeleton.Edge(from: "neck", to: "nose"),
                Skeleton.Edge(from: "neck", to: "leftShoulder"),
            ]),
            sourceModelID: "detection-layer-tests"
        )

        let segments = DetectionLayer<PlayerLayerConverter>.skeletonSegments(of: detection)
        let unwrapped = try? #require(segments)
        #expect(unwrapped?.count == 2)
        #expect(unwrapped?[0].0 == neck)
        #expect(unwrapped?[0].1 == nose)
        #expect(unwrapped?[1].0 == neck)
        #expect(unwrapped?[1].1 == leftShoulder)
    }

    @Test
    func skeletonSegmentsSkipsEdgeWithMissingEndpoint() {
        // The "nose" joint is absent, so the neck–nose edge is skipped while
        // the neck–leftShoulder edge (both present) survives.
        let neck = CGPoint(x: 0.5, y: 0.8)
        let leftShoulder = CGPoint(x: 0.4, y: 0.78)
        let detection = Detection(
            boundingBox: CGRect(x: 0.4, y: 0.78, width: 0.1, height: 0.02),
            label: "person",
            confidence: 0.9,
            keypoints: [
                Detection.Keypoint(name: "neck", position: neck, confidence: 0.9),
                Detection.Keypoint(name: "leftShoulder", position: leftShoulder, confidence: 0.9),
            ],
            skeleton: Skeleton(edges: [
                Skeleton.Edge(from: "neck", to: "nose"),  // nose missing → skipped
                Skeleton.Edge(from: "neck", to: "leftShoulder"),
            ]),
            sourceModelID: "detection-layer-tests"
        )

        let segments = DetectionLayer<PlayerLayerConverter>.skeletonSegments(of: detection)
        let unwrapped = try? #require(segments)
        #expect(unwrapped?.count == 1)
        #expect(unwrapped?[0].0 == neck)
        #expect(unwrapped?[0].1 == leftShoulder)
    }

    @Test
    func skeletonSegmentsReturnsNilForBoxOnlyDetection() {
        let detection = Detection(
            boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4),
            label: "box",
            confidence: 0.9,
            sourceModelID: "detection-layer-tests"
        )
        #expect(DetectionLayer<PlayerLayerConverter>.skeletonSegments(of: detection) == nil)
    }

    @Test
    func skeletonSegmentsReturnsNilForQuadDetection() {
        // A quad (corner keypoints, no skeleton) is not a skeleton — the
        // helper returns nil so the caller falls through to the quad path.
        let detection = Detection(
            boundingBox: CGRect(x: 0.38, y: 0.60, width: 0.28, height: 0.28),
            label: "tilted",
            confidence: 0.88,
            keypoints: [
                Detection.Keypoint(
                    name: "topLeft", position: .init(x: 0.38, y: 0.82), confidence: 1.0),
                Detection.Keypoint(
                    name: "topRight", position: .init(x: 0.60, y: 0.88), confidence: 1.0),
                Detection.Keypoint(
                    name: "bottomRight", position: .init(x: 0.66, y: 0.66), confidence: 1.0),
                Detection.Keypoint(
                    name: "bottomLeft", position: .init(x: 0.44, y: 0.60), confidence: 1.0),
            ],
            sourceModelID: "detection-layer-tests"
        )
        #expect(DetectionLayer<PlayerLayerConverter>.skeletonSegments(of: detection) == nil)
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
