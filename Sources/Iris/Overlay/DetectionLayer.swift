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

    /// Stroked-box + label render. Stroke and label colors / font / text
    /// come from `style`; the box geometry comes from the injected
    /// `converter`.
    private static func draw(
        _ detection: Detection,
        into gc: inout GraphicsContext,
        converter: Converter,
        videoRect: CGRect,
        style: OverlayStyle
    ) {
        let rect = converter.viewRect(forNormalized: detection.boundingBox, in: videoRect)

        // Box outline.
        gc.stroke(
            Path(rect),
            with: .color(style.color(for: detection.label)),
            lineWidth: style.strokeWidth
        )

        // Label, if the formatter produced a non-empty string. The default
        // formatter returns `""` for empty-label detections, so that branch
        // suppresses the backplate automatically.
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
            x: rect.minX,
            y: rect.minY - backplateHeight,
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
/// centered easy box, edge-clipped box, low-confidence box (exercises the
/// label format with %), and an empty-label box (the default `labelFormat`
/// suppresses the backplate for that one).
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
