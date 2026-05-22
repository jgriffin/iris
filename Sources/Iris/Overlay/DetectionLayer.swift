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
/// **`displayTime` source.** In M2 the only consumer is live capture, so
/// `displayTime` is read from the host clock — `CMClockGetTime(CMClockGetHostTimeClock())`
/// — to match the reference frame of `CMSampleBuffer.presentationTimeStamp`
/// vended by `AVCaptureVideoDataOutput`. M3 playback rewires this to
/// `AVPlayer.currentTime` via `addPeriodicTimeObserver` (locked decision 12).
/// Either source produces a `CMTime` in the same domain the `ResultStore`
/// was filled from, which is what makes the lookup correct.
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
/// **Hardcoded styling for Phase 5.** Stroke width, stroke color, and label
/// formatting are baked into this file pending the Phase 6 `OverlayStyle`
/// introduction. Don't pre-introduce the style type here.
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

    /// Per-call override of `ResultStore.liveStalenessThreshold`. `nil` (the
    /// default) uses the store's `liveStalenessThreshold`; playback consumers
    /// pass `store.playbackStalenessThreshold` here.
    public let stalenessThreshold: CMTime?

    public init(
        store: ResultStore,
        converter: Converter,
        videoRect: CGRect,
        stalenessThreshold: CMTime? = nil
    ) {
        self.store = store
        self.converter = converter
        self.videoRect = videoRect
        self.stalenessThreshold = stalenessThreshold
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { _ in
            // Host-clock `displayTime` — matches the reference frame of
            // `CMSampleBuffer.presentationTimeStamp` vended by AVF capture.
            // M3 playback will override this read with `AVPlayer.currentTime`
            // and pipe it through a binding; for M2 live capture, host clock
            // is the right source.
            let displayTime = CMClockGetTime(CMClockGetHostTimeClock())
            let detections = store.lookup(at: displayTime, stale: stalenessThreshold)

            Canvas { gc, _ in
                for detection in detections {
                    Self.draw(detection, into: &gc, converter: converter, videoRect: videoRect)
                }
            }
            .drawingGroup()
            .allowsHitTesting(false)
        }
    }

    // MARK: - Drawing

    /// Hardcoded box + label render. Phase 6 makes stroke/color/label format
    /// configurable via `OverlayStyle`; don't introduce that here.
    private static func draw(
        _ detection: Detection,
        into gc: inout GraphicsContext,
        converter: Converter,
        videoRect: CGRect
    ) {
        let rect = converter.viewRect(forNormalized: detection.boundingBox, in: videoRect)

        // Box outline.
        let strokeColor = Color(red: 0.20, green: 0.85, blue: 1.0)
        gc.stroke(Path(rect), with: .color(strokeColor), lineWidth: 1.5)

        // Label, if non-empty. Drawn at the top-left corner of the box with a
        // semi-transparent black backplate so the white text reads against
        // any video content underneath.
        guard !detection.label.isEmpty else { return }
        let labelText = Text(detection.label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white)
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
        gc.fill(Path(backplate), with: .color(.black.opacity(0.6)))
        gc.draw(
            resolved,
            at: CGPoint(x: backplate.minX + padding, y: backplate.minY + padding),
            anchor: .topLeading
        )
    }
}
