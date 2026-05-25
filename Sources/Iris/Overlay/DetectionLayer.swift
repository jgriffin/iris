import CoreMedia
import SwiftUI

/// SwiftUI overlay that draws bounding boxes for the most-recent
/// `[Detection]` whose timestamp is `<= displayTime`.
///
/// The view is driven by a 60 Hz `TimelineView(.animation)` so the overlay
/// redraws smoothly independent of detector cadence (locked decision 9 in
/// `explorations/display-pipeline-architecture/RECOMMENDATIONS.md`). The
/// inner `Canvas` carries `.drawingGroup()` (Metal-backed offscreen render)
/// and `.allowsHitTesting(false)` (gestures pass through to the underlying
/// preview / player) — both locked, no knobs (decision 8).
///
/// **`displayTime` source.** Read from the injected `displayTimeSource`
/// closure at each `TimelineView` tick. The default reads
/// `CMClockGetTime(CMClockGetHostTimeClock())` — correct for live capture,
/// since it matches the reference frame of `CMSampleBuffer.presentationTimeStamp`
/// vended by `AVCaptureVideoDataOutput`. M3 playback consumers pass
/// `{ player.currentTime() }` (or `{ binding.wrappedValue }` to plumb a
/// scrub binding through) without needing a separate init overload.
///
/// **Best-effort overlay** (locked decision 11). `lookup(at: displayTime)`
/// is pure best-effort with no latency compensation — live boxes trail the
/// subject by detection latency. Apps that want zero-lag overlays predict
/// ahead of `ResultStore.append`; Iris does not.
///
/// **Required `converter:`.** The locked sketch defaulted to
/// `PlayerLayerConverter()`; resolved at Phase 5 to drop the default. A
/// converter without a backing AVF layer has no useful runtime behavior, and
/// the call site is the natural place to be explicit (`PreviewLayerConverter`
/// for camera, `PlayerLayerConverter` for playback). See the LOG entry for
/// Phase 4 close and the `_Amendment 2026-05-22:_` note in the recommendation
/// doc.
///
/// **Styling via `OverlayStyle`** (Phase 6). Stroke width, per-class stroke
/// color, label format, label text/background color, and label font are all
/// configured via `style:`. The default `OverlayStyle()` reproduces the
/// Phase 5 hardcoded visuals.
public struct DetectionLayer<Converter: NormalizedGeometryConverting>: View {

    /// The result store the overlay reads at draw time. `@MainActor`-isolated
    /// internally; the SwiftUI `Canvas` body is also `@MainActor`, so the
    /// `lookup(at:)` call is direct (no actor hop).
    public let store: ResultStore

    /// The geometry converter — `PreviewLayerConverter` for capture,
    /// `PlayerLayerConverter` for playback. Required (no default); see the
    /// type doc-comment for the Phase 5 resolution.
    public let converter: Converter

    /// The on-screen rect the video pixels occupy after aspect-fit
    /// letterbox/pillarbox. For `PreviewLayerConverter` this is ignored
    /// (AVF computes it internally); for `PlayerLayerConverter` callers
    /// pass `AVPlayerLayer.videoRect` (M3 surfaces this reactively via
    /// `PlaybackSession.videoRect: AsyncStream<CGRect>`).
    public let videoRect: CGRect

    /// Style knobs for stroke and label rendering. Defaults to the
    /// Phase-5-equivalent `OverlayStyle()`.
    public let style: OverlayStyle

    /// Per-call override of `ResultStore.liveStalenessThreshold`. `nil` (the
    /// default) uses the store's `liveStalenessThreshold`; playback consumers
    /// pass `store.playbackStalenessThreshold` here.
    public let stalenessThreshold: CMTime?

    /// Closure invoked each `TimelineView` tick to read the current
    /// `displayTime`. Default reads the host clock — correct for live
    /// capture. M3 playback callers pass `{ player.currentTime() }` or
    /// `{ binding.wrappedValue }` to feed an `AVPlayer.currentTime` or
    /// scrub binding through without a second init overload.
    public let displayTimeSource: @Sendable () -> CMTime

    /// Optional tuning router consulted at *draw time* for an output-stage
    /// transform.
    ///
    /// **Why draw-time, not pipeline-time alone.** `DetectorPipeline` already
    /// applies `tuning.transform` to its own return value (both cache-hit
    /// and fresh-inference paths). But the overlay reads `ResultStore.lookup(at:)`
    /// directly on every `TimelineView` tick — independent of pipeline runs.
    /// When the source is paused, no frames flow → no pipeline runs → filter
    /// changes are invisible. Consulting the router here makes filter-tier
    /// knob changes reactive even when the source is idle: the overlay
    /// redraws on the next animation tick with the new transform applied.
    ///
    /// `nil` (the default) preserves pre-M4 behavior — every cached detection
    /// in `lookup(at:)` is drawn unfiltered.
    public let tuning: (any TuningRouter)?

    public init(
        store: ResultStore,
        converter: Converter,
        videoRect: CGRect,
        style: OverlayStyle = .default,
        stalenessThreshold: CMTime? = nil,
        tuning: (any TuningRouter)? = nil,
        displayTimeSource: @Sendable @escaping () -> CMTime = {
            CMClockGetTime(CMClockGetHostTimeClock())
        }
    ) {
        self.store = store
        self.converter = converter
        self.videoRect = videoRect
        self.style = style
        self.stalenessThreshold = stalenessThreshold
        self.tuning = tuning
        self.displayTimeSource = displayTimeSource
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { _ in
            let displayTime = displayTimeSource()
            let raw = store.lookup(at: displayTime, stale: stalenessThreshold)
            let detections = Self.applyTransform(tuning?.transform, to: raw)

            Canvas { gc, _ in
                for detection in detections {
                    Self.draw(
                        detection,
                        into: &gc,
                        converter: converter,
                        videoRect: videoRect,
                        style: style
                    )
                }
            }
            .drawingGroup()
            .allowsHitTesting(false)
        }
    }

    /// Apply an optional output-stage transform to a detection list.
    /// Pulled out as a `static` helper so unit tests can exercise the
    /// transform-application path without rendering — SwiftUI's `Canvas`
    /// body is opaque to tests, but this helper takes the same
    /// `(transform, raw)` inputs the body uses and returns the
    /// projected list.
    ///
    /// `transform == nil` returns the input array by identity — no
    /// allocation for the common no-transform case (the overwhelming
    /// majority of capture call sites).
    @inlinable
    public static func applyTransform(
        _ transform: (@Sendable ([Detection]) -> [Detection])?,
        to detections: [Detection]
    ) -> [Detection] {
        guard let transform else { return detections }
        return transform(detections)
    }

    // MARK: - Drawing

    /// The four oriented corners of a detected quadrilateral, in
    /// `topLeft → topRight → bottomRight → bottomLeft` order, in normalized
    /// (Vision bottom-left origin) coordinates — if the detection carries all
    /// four documented corner keypoints. Vision rectangle detections populate
    /// these (the documented corner-name invariant in `VisionRectanglesDetector`);
    /// box-only detections (no keypoints, or non-corner keypoints) return `nil`,
    /// and the caller falls back to the axis-aligned bounding box.
    static func quadCorners(of detection: Detection) -> [CGPoint]? {
        guard let keypoints = detection.keypoints else { return nil }
        let cornerNames = ["topLeft", "topRight", "bottomRight", "bottomLeft"]
        var corners: [CGPoint] = []
        corners.reserveCapacity(4)
        for name in cornerNames {
            guard let kp = keypoints.first(where: { $0.name == name }) else { return nil }
            corners.append(kp.position)
        }
        return corners
    }

    /// The drawable line segments of a detection's skeleton, as NORMALIZED
    /// (Vision bottom-left origin) endpoint pairs — one per `Skeleton.Edge`
    /// whose *both* endpoints resolve to a present keypoint. Edges with a
    /// missing endpoint are skipped (a partially-occluded pose still draws
    /// the limbs it has).
    ///
    /// Returns `nil` when the detection carries no skeleton
    /// (`detection.skeleton == nil`) or no keypoints — the caller then falls
    /// back to the quad / box paths. The overlay holds NO joint knowledge:
    /// the topology is read entirely off the detection's own `skeleton`.
    ///
    /// Pure function of the detection; pulled out so tests can exercise the
    /// name-resolution and skip-missing-endpoint logic without rendering.
    static func skeletonSegments(of detection: Detection) -> [(CGPoint, CGPoint)]? {
        guard let skeleton = detection.skeleton else { return nil }
        guard let keypoints = detection.keypoints, !keypoints.isEmpty else { return nil }

        var positions: [String: CGPoint] = [:]
        positions.reserveCapacity(keypoints.count)
        for kp in keypoints {
            positions[kp.name] = kp.position
        }

        var segments: [(CGPoint, CGPoint)] = []
        segments.reserveCapacity(skeleton.edges.count)
        for edge in skeleton.edges {
            guard let from = positions[edge.from], let to = positions[edge.to] else { continue }
            segments.append((from, to))
        }
        return segments
    }

    /// Stroked-skeleton / quad / box + label render. Stroke and label colors
    /// / font / text come from `style`; geometry comes from the injected
    /// `converter`.
    ///
    /// Geometry dispatch order: **skeleton → quad → box.** A detection that
    /// carries a `skeleton` (pose) is drawn as connected joints; one that
    /// carries four oriented corners is drawn as a quad; everything else
    /// falls back to the axis-aligned bounding box. The label anchor is
    /// always the bounding-box top-left, regardless of which geometry drew.
    private static func draw(
        _ detection: Detection,
        into gc: inout GraphicsContext,
        converter: Converter,
        videoRect: CGRect,
        style: OverlayStyle
    ) {
        let rect = converter.viewRect(forNormalized: detection.boundingBox, in: videoRect)
        let strokeColor = style.color(for: detection.label)

        if let segments = skeletonSegments(of: detection) {
            // Skeleton: stroke each present edge, then dot each joint. Every
            // point goes through the centralized converter — never re-derive
            // the Y-flip here.
            for (from, to) in segments {
                var line = Path()
                line.move(to: converter.viewPoint(forNormalized: from, in: videoRect))
                line.addLine(to: converter.viewPoint(forNormalized: to, in: videoRect))
                gc.stroke(line, with: .color(strokeColor), lineWidth: style.strokeWidth)
            }
            if let keypoints = detection.keypoints {
                let dotRadius = max(style.strokeWidth * 1.5, 2.5)
                for kp in keypoints {
                    let center = converter.viewPoint(forNormalized: kp.position, in: videoRect)
                    let dot = CGRect(
                        x: center.x - dotRadius,
                        y: center.y - dotRadius,
                        width: dotRadius * 2,
                        height: dotRadius * 2
                    )
                    gc.fill(Path(ellipseIn: dot), with: .color(strokeColor))
                }
            }
            drawLabel(detection, into: &gc, anchorRect: rect, style: style)
            return
        }

        // Outline: the real detected quad when the detection carries oriented
        // corner keypoints (capability-honest — draw the geometry that actually
        // came back), else the axis-aligned bounding box.
        let outline: Path
        if let corners = quadCorners(of: detection) {
            var path = Path()
            path.addLines(corners.map { converter.viewPoint(forNormalized: $0, in: videoRect) })
            path.closeSubpath()
            outline = path
        } else {
            outline = Path(rect)
        }
        gc.stroke(
            outline,
            with: .color(strokeColor),
            lineWidth: style.strokeWidth
        )

        drawLabel(detection, into: &gc, anchorRect: rect, style: style)
    }

    /// Draw the label backplate + text, anchored to the top-left of
    /// `anchorRect` (the converted bounding box). Shared by every geometry
    /// path so the label placement is identical whether a skeleton, quad, or
    /// box drew the detection.
    ///
    /// If the formatter produced an empty string (the default formatter does
    /// so for empty-label detections), nothing is drawn.
    private static func drawLabel(
        _ detection: Detection,
        into gc: inout GraphicsContext,
        anchorRect: CGRect,
        style: OverlayStyle
    ) {
        let labelString = style.labelFormat(detection)
        guard !labelString.isEmpty else { return }

        let labelText = Text(labelString)
            .font(style.labelFont)
            .foregroundColor(style.labelTextColor)
        let resolved = gc.resolve(labelText)
        let measureBounds = CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        let textSize = resolved.measure(in: measureBounds)
        let padding: CGFloat = 3
        let backplateWidth = textSize.width + padding * 2
        let backplateHeight = textSize.height + padding * 2
        let backplate = CGRect(
            x: anchorRect.minX,
            y: anchorRect.minY - backplateHeight,
            width: backplateWidth,
            height: backplateHeight
        )
        gc.fill(Path(backplate), with: .color(style.labelBackgroundColor))
        gc.draw(
            resolved,
            at: CGPoint(x: backplate.minX + padding, y: backplate.minY + padding),
            anchor: .topLeading
        )
    }
}

// MARK: - Previews

/// Synthetic fixture used by the `#Preview` cases below — a tight set of
/// detections covering the visual edge cases that matter for spot-checks:
/// centered box, edge-clipped box, a third generic box, and an empty-label
/// box (the default `labelFormat` suppresses the backplate for that one).
/// The generic boxes carry no `readout`, so the honest default label shows
/// just their label — no fabricated confidence percentage. The tilted
/// rectangle and the pose carry their detector's real readout (aspect ratio,
/// joint count), which the default formatter appends after the label.
@MainActor
private func previewStore() -> ResultStore {
    let store = ResultStore()
    let displayTime = CMTime(value: 100, timescale: 60)
    let detections: [Detection] = [
        Detection(
            boundingBox: CGRect(x: 0.30, y: 0.30, width: 0.40, height: 0.40),
            label: "subject",
            confidence: 0.94,
            sourceModelID: "preview"
        ),
        Detection(
            boundingBox: CGRect(x: -0.05, y: 0.55, width: 0.30, height: 0.20),
            label: "edge",
            confidence: 0.71,
            sourceModelID: "preview"
        ),
        Detection(
            boundingBox: CGRect(x: 0.65, y: 0.10, width: 0.20, height: 0.15),
            label: "low_conf",
            confidence: 0.23,
            sourceModelID: "preview"
        ),
        Detection(
            boundingBox: CGRect(x: 0.10, y: 0.05, width: 0.18, height: 0.18),
            label: "",
            confidence: 0.50,
            sourceModelID: "preview"
        ),
        // Tilted rectangle (~20°): corner keypoints do not line up with the
        // axis-aligned envelope, so the quad outline is visibly different
        // from the bounding box. boundingBox is the envelope of the corners.
        Detection(
            boundingBox: CGRect(x: 0.38, y: 0.60, width: 0.28, height: 0.28),
            label: "tilted",
            confidence: 0.88,
            keypoints: [
                Detection.Keypoint(
                    name: "topLeft", position: CGPoint(x: 0.38, y: 0.82), confidence: 1.0),
                Detection.Keypoint(
                    name: "topRight", position: CGPoint(x: 0.60, y: 0.88), confidence: 1.0),
                Detection.Keypoint(
                    name: "bottomRight", position: CGPoint(x: 0.66, y: 0.66), confidence: 1.0),
                Detection.Keypoint(
                    name: "bottomLeft", position: CGPoint(x: 0.44, y: 0.60), confidence: 1.0),
            ],
            readout: Readout(label: "aspect", text: "1.30:1"),
            sourceModelID: "preview"
        ),
        // Body pose: a synthetic upright figure at hardcoded normalized
        // positions (Vision bottom-left origin, so the head is at high y and
        // the feet at low y). Names match `Skeleton.humanBodyPose` edges so
        // the skeleton renders; boundingBox is the joint envelope.
        Detection(
            boundingBox: CGRect(x: 0.06, y: 0.06, width: 0.16, height: 0.86),
            label: "person",
            confidence: 0.82,
            keypoints: [
                Detection.Keypoint(
                    name: "nose", position: CGPoint(x: 0.14, y: 0.92), confidence: 0.97),
                Detection.Keypoint(
                    name: "leftEye", position: CGPoint(x: 0.12, y: 0.93), confidence: 0.9),
                Detection.Keypoint(
                    name: "rightEye", position: CGPoint(x: 0.16, y: 0.93), confidence: 0.9),
                Detection.Keypoint(
                    name: "leftEar", position: CGPoint(x: 0.10, y: 0.92), confidence: 0.8),
                Detection.Keypoint(
                    name: "rightEar", position: CGPoint(x: 0.18, y: 0.92), confidence: 0.8),
                Detection.Keypoint(
                    name: "neck", position: CGPoint(x: 0.14, y: 0.86), confidence: 0.95),
                Detection.Keypoint(
                    name: "leftShoulder", position: CGPoint(x: 0.08, y: 0.84), confidence: 0.93),
                Detection.Keypoint(
                    name: "rightShoulder", position: CGPoint(x: 0.20, y: 0.84), confidence: 0.93),
                Detection.Keypoint(
                    name: "leftElbow", position: CGPoint(x: 0.06, y: 0.72), confidence: 0.85),
                Detection.Keypoint(
                    name: "rightElbow", position: CGPoint(x: 0.22, y: 0.72), confidence: 0.85),
                Detection.Keypoint(
                    name: "leftWrist", position: CGPoint(x: 0.07, y: 0.60), confidence: 0.8),
                Detection.Keypoint(
                    name: "rightWrist", position: CGPoint(x: 0.21, y: 0.60), confidence: 0.8),
                Detection.Keypoint(
                    name: "root", position: CGPoint(x: 0.14, y: 0.58), confidence: 0.9),
                Detection.Keypoint(
                    name: "leftHip", position: CGPoint(x: 0.11, y: 0.56), confidence: 0.88),
                Detection.Keypoint(
                    name: "rightHip", position: CGPoint(x: 0.17, y: 0.56), confidence: 0.88),
                Detection.Keypoint(
                    name: "leftKnee", position: CGPoint(x: 0.10, y: 0.32), confidence: 0.82),
                Detection.Keypoint(
                    name: "rightKnee", position: CGPoint(x: 0.18, y: 0.32), confidence: 0.82),
                Detection.Keypoint(
                    name: "leftAnkle", position: CGPoint(x: 0.09, y: 0.08), confidence: 0.75),
                Detection.Keypoint(
                    name: "rightAnkle", position: CGPoint(x: 0.19, y: 0.08), confidence: 0.75),
            ],
            skeleton: .humanBodyPose,
            readout: Readout(label: "joints", text: "19 joints"),
            sourceModelID: "preview"
        ),
    ]
    store.append(TimestampedDetections(timestamp: displayTime, detections: detections))
    return store
}

#Preview("DetectionLayer · default style") {
    let store = previewStore()
    let frozen = CMTime(value: 100, timescale: 60)
    let videoRect = CGRect(x: 0, y: 0, width: 360, height: 240)

    return ZStack {
        Color.black
        DetectionLayer(
            store: store,
            converter: PlayerLayerConverter(),
            videoRect: videoRect,
            displayTimeSource: { frozen }
        )
    }
    .frame(width: videoRect.width, height: videoRect.height)
}

#Preview("DetectionLayer · custom style") {
    let store = previewStore()
    let frozen = CMTime(value: 100, timescale: 60)
    let videoRect = CGRect(x: 0, y: 0, width: 360, height: 240)

    let style = OverlayStyle(
        strokeWidth: 2.5,
        strokeColor: { label in
            switch label {
            case "subject": return .green
            case "edge": return .orange
            case "low_conf": return .red
            default: return .gray
            }
        },
        labelFormat: { detection in
            let pct = Int(detection.confidence * 100)
            return detection.label.isEmpty ? "?" : "\(detection.label) · \(pct)"
        },
        labelTextColor: .black,
        labelBackgroundColor: .yellow.opacity(0.85),
        labelFont: .system(size: 12, weight: .bold)
    )

    return ZStack {
        Color.black
        DetectionLayer(
            store: store,
            converter: PlayerLayerConverter(),
            videoRect: videoRect,
            style: style,
            displayTimeSource: { frozen }
        )
    }
    .frame(width: videoRect.width, height: videoRect.height)
}
