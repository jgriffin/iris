# Display-pipeline architecture — locked decisions for M1+

**Read date:** 2026-05-20
**Source:** distilled from [`SYNTHESIS.md`](./SYNTHESIS.md). Composes on top of the sibling block's [`../runtime-pipeline-architecture/RECOMMENDATIONS.md`](../runtime-pipeline-architecture/RECOMMENDATIONS.md) — every decision here is consistent with the sibling's 20 source-side locks, in particular the single-consumer `.bufferingNewest(1)` contract on `Source.frames` and the ban on `AVPlayerItemVideoOutput`. Cites M0 verdicts at [`../prior-projects/RECOMMENDATIONS.md`](../prior-projects/RECOMMENDATIONS.md) and the AVCam pattern at [`../swift-ecosystem/apple-avcam.md`](../swift-ecosystem/apple-avcam.md). Mirror the sibling's voice — these are *locked decisions* on the display side of Iris (preview, player, overlay, frame-sync), to be folded into M1/M2/M3 plans without further debate.

---

## Locked decisions

### Display surfaces

1. **Capture preview is `AVCaptureVideoPreviewLayer` hosted by a `UIView` whose `layerClass` is `AVCaptureVideoPreviewLayer.self`.**
   *Rationale:* canonical AVF-native, hardware-accelerated preview for `AVCaptureSession`. No alternative makes sense at iOS 26. The `layerClass` override (vs. `addSublayer(...)`) avoids sublayer geometry management and is the textbook iOS SwiftUI-AVPlayer/AVPreview pattern (Apple AVCam, every iOS preview tutorial).
   *M1 must:* declare `internal final class PreviewView: UIView` with `override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }`. Public `CameraPreview: UIViewRepresentable` wraps `PreviewView`; SwiftUI never sees the `UIView` type or the layer.

2. **Playback display is `AVPlayer` + `AVPlayerLayer` — NOT `AVSampleBufferDisplayLayer`, NOT manual Metal/CI compositing, NOT SwiftUI's `VideoPlayer`.**
   *Rationale:* `AVPlayer` is the high-level surface AVF provides for "play this asset, handle seek/scrub/pause/rate/audio." `AVSampleBufferDisplayLayer` is the low-level alternative for custom decode pipelines — reimplementing AVPlayer's clock, seek, scrubbing, audio sync would cost hundreds of lines for zero gain. `VideoPlayer` (AVKit SwiftUI) ships built-in transport controls that fight a custom overlay; it also doesn't expose `videoRect`. Manual rendering means tying display to `AVAssetReader` (sibling-banned for the display path because the asset-reader is already the analysis path).
   *M1 must:* `PlaybackSession` constructs `AVPlayer(playerItem: AVPlayerItem(url: url))`; vends it via `PlaybackPreviewSource` (decision 5). Public surface never exposes `AVPlayer`.

3. **`AVPlayerLayer` is hosted by a `UIView` (iOS, `layerClass` override) or an `NSView` (macOS, manual `wantsLayer = true; layer = AVPlayerLayer()`).**
   *Rationale:* a bare layer-backed view gives Iris the `videoRect` access the overlay needs and keeps both platforms symmetric. AVKit's `AVPlayerView` (macOS) is rejected — it ships its own controls that compete with Iris's overlay and `IrisTuning` scrubber. The platform fork is contained to ~25 lines per platform inside the `PlayerView` body (`#if os(iOS) PlayerHostiOS #elseif os(macOS) PlayerHostMac #endif`).
   *M1/M3 must:* `internal final class PlayerHostUIView: UIView` (iOS) with `override class var layerClass: AnyClass { AVPlayerLayer.self }`. `internal final class PlayerHostNSView: NSView` (macOS) with `init` setting `wantsLayer = true; layer = AVPlayerLayer()`. Both conform to `PlaybackPreviewTarget`.

4. **`videoGravity` defaults to `.resizeAspect`** on both `AVCaptureVideoPreviewLayer` and `AVPlayerLayer`.
   *Rationale:* aspect-fit with letterbox/pillarbox is the right default — preserves content, predictable geometry. `resizeAspectFill` crops; `resize` distorts. The overlay's coordinate math (`NormalizedGeometryConverting`) is built against the `videoRect` that aspect-fit produces.
   *M1 must:* both `PreviewView.setSession` and `PlayerHost*.setPlayer` set `videoGravity = .resizeAspect` on the layer. Configurability deferred to a future block (likely styling, M4); not exposed in M1.

### Source/display fan-out

5. **Display does NOT consume `Source.frames`. `Source` stays single-consumer.**
   *Rationale:* the load-bearing architectural decision in this block. The two consumers (display, detector) tap *different AVF surfaces* of the same root session/asset — display gets pixels from the preview-layer / player-layer (hardware-paced, AVF-native), the detector gets `Frame`s from the data-output / asset-reader (paced by the consumer, with `.bufferingNewest(1)` back-pressure). They share the session/asset and the time domain, but not pixels or buffering. Sibling decision 14 (`.bufferingNewest(1)`, single consumer) is trivially preserved — display isn't a consumer at all.
   *M1 must:* `IrisCapture`'s `AVCaptureSession` has two outputs attached: `AVCaptureVideoDataOutput` (data path, sibling-owned) and the implicit preview layer (via `previewLayer.session = session`). `IrisPlayback`'s asset URL has two decoders: `AVPlayer` (display) and `AVAssetReader` (analysis). Code review block: any code that tries to feed pixels to display from the `Source.frames` stream.

6. **The mechanism for vending the display path through the actor wall is a `Sendable` source / `@MainActor` target protocol pair (mirroring sibling decision 15).**
   *Rationale:* same reason as `PreviewSource`/`PreviewTarget` — never expose `AVCaptureSession` or `AVPlayer` directly. The `nonisolated let *previewSource: *PreviewSource` opening in the actor wall holds a `Sendable` indirection; the SwiftUI view's `UIView`/`NSView` host conforms to `*PreviewTarget` and receives the AVF object inside `@MainActor`.
   *M1/M3 must:* `PreviewSource` + `PreviewTarget` (iOS capture, sibling-locked). `PlaybackPreviewSource` + `PlaybackPreviewTarget` (iOS+macOS playback, new in this block — symmetric to capture's pair). All four are public; the concrete `AVCapturePreviewSource` / `AVPlaybackPreviewSource` are internal.

### Overlay layer

7. **Overlay is pure SwiftUI `Canvas` in a `ZStack` over the display view. NOT `AVSynchronizedLayer`, NOT custom `CALayer` composition, NOT `UIBezierPath`/`NSBezierPath`.**
   *Rationale:* `AVSynchronizedLayer` only works with `AVPlayerItem` (no `AVCaptureSession` variant exists) — disqualifies it from Iris's "same overlay for live and playback" principle. Custom `CALayer` requires platform-aware geometry plumbing and re-introduces the `#if os` proliferation Iris is built to avoid. SportVision proved SwiftUI `Canvas` runs identically on iOS and macOS in ~170 LOC. `UIBezierPath`/`NSBezierPath` were explicitly banned by M0 (`../prior-projects/SYNTHESIS.md` §Q5).
   *M2 must:* `DetectionLayer: View` with `Canvas` inside, no platform forks in the overlay file. Zero `import UIKit`, zero `import AppKit`. Pure SwiftUI primitives (`Path`, `Color`, `Text`, `Canvas`).

8. **`Canvas` overlay carries `.drawingGroup()` and `.allowsHitTesting(false)`.**
   *Rationale:* `.drawingGroup()` is Metal-backed offscreen rendering — measurably smoother at 60 Hz with many boxes; SportVision uses it and Apple's WWDC21 graphics talk recommends it for animated `Canvas` content. `.allowsHitTesting(false)` lets gestures pass through to the underlying player/preview (e.g. tap-to-pause). The Hacking-with-Swift caveat "only after measuring" — we have the measurement from SportVision; it pays off.
   *M2 must:* both modifiers applied to the `Canvas` inside `DetectionLayer`. Don't expose either as a knob.

9. **Overlay redraw cadence is driven by a `TimelineView(.animation(minimumInterval: 1.0/60))` around the `Canvas`.**
   *Rationale:* the overlay needs a redraw clock independent of when detection results arrive — specifically so playback scrub redraws the overlay smoothly while the slider drags (and the player's `currentTime` changes faster than the detector produces results). For live capture, the `TimelineView` redraws at host rate, but the actual `Canvas` redraw is cheap because the looked-up `[Detection]` is `Equatable`-stable across most ticks. The trap (`heavy work inside TimelineView` per Apple's WWDC21 SwiftUI talk) is avoided — the lookup is O(log n) on a small array.
   *M2 must:* `TimelineView(.animation(minimumInterval: 1.0/60))` wraps the `Canvas`. The closure does `let dets = resultStore.lookup(at: displayTime); Canvas { … draw(dets) … }`.

### Frame synchronization

10. **Detection results are tagged with their source `Frame.timestamp` and stored in a sorted ring buffer keyed by timestamp.**
    *Rationale:* the only honest way to reconverge a delayed analysis path with a live display path is by *time*, not by frame identity. `Frame.timestamp` is `CMTime` (sibling decision 9), already first-class; tagging the result is a one-line wrapper. PRVisionSpike's `VisionTimestampedObservations` is the precedent for the sorted-array + binary-search-lookup shape.
    *M2 must:* `public struct TimestampedDetections: Sendable, Hashable { let timestamp: CMTime; let detections: [Detection] }`. `public @MainActor @Observable final class ResultStore` with `append`, `clear`, `lookup(at: CMTime) -> [Detection]`. Lookup is O(log n) via `binarySearchInsertion`.

11. **Overlay reads `displayTime` at draw time and does `lookup(at: displayTime - 0)`. No artificial latency compensation in Iris.**
    *Rationale:* "best-effort" overlay in live capture is the honest contract: boxes trail subject by Δ (detection latency), and that's unavoidable without forward prediction. Forward prediction is a domain choice (Kalman, optical flow, model-specific motion priors) and lives in downstream apps, not in Iris. Iris exposes the lookup; apps that want zero-lag predict ahead before calling `resultStore.append`.
    *M2 must:* `DetectionLayer` calls `resultStore.lookup(at: displayTime)` in the `TimelineView` closure. No Δ subtraction inside Iris. Document the lag as a known property of the overlay in `DetectionLayer`'s doc-comment.

12. **`displayTime` is sourced from three places, by mode: live = host clock, playback = `AVPlayer.currentTime` (via `addPeriodicTimeObserver`), scrub = slider `Binding`.**
    *Rationale:* one overlay API, three timing sources, depending on context. The overlay doesn't care which — it just reads `displayTime` and looks up. `addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main)` is the standard pattern for SwiftUI-bound playback time.
    *M3 must:* `PlaybackSession` exposes `currentTime: AsyncStream<CMTime>` backed by a periodic time observer at 60 Hz; consumers `for await time in session.currentTime { displayTime = time }`. M2's live-capture context just reads host clock from a `Timer.publish(every: 1.0/60, …)` or equivalent.

13. **Staleness check: if the most-recent result in the buffer is older than 500 ms (live) / 2 s (playback), `lookup` returns `[]`.**
    *Rationale:* avoid sticky-overlay artifacts where the detector has hung or died but the last result keeps re-rendering. Surface "detector is broken" visually as "no boxes" rather than "wrong boxes." 500 ms for live (the user expects responsive boxes; older than that is clearly stale); 2 s for playback (asset-length scrubs can leave gaps, especially during seek).
    *M2 must:* implement in `ResultStore.lookup(at:)`. Both thresholds are public constants; apps can override for domain reasons.

14. **`PlaybackSession.seek(to:)` clears the result store before the new reader starts producing.**
    *Rationale:* after seek, the buffered results are from before the seek and don't correspond to the new playback range. Showing them is worse than showing nothing. Clear-on-seek is cheap and obvious.
    *M3 must:* `PlaybackSession.seek(to:)` exposes a `willSeek` hook (or returns an `AsyncStream<SeekEvent>`) so consumers can `resultStore.clear()` before the reader restarts.

### Coordinate-space conversion

15. **`NormalizedGeometryConverting` protocol lives in `IrisOverlay`, with two implementations: `PreviewLayerConverter` (delegates to `AVCaptureVideoPreviewLayer.layerRectConverted(...)`) and `PlayerLayerConverter` (aspect-fit math against `AVPlayerLayer.videoRect`).**
    *Rationale:* M0 verdict (`../prior-projects/RECOMMENDATIONS.md` §"Overlay & coordinate math"). The Y-flip and letterbox math live in one place; callers never write `1 - y - h`. ActionAndVision's `NormalizedGeometryConverting` protocol with per-source backends is the canonical shape.
    *M2 must:* `public protocol NormalizedGeometryConverting` with `viewRect(forNormalized:in:)` and `viewPoint(forNormalized:in:)`. Two `public struct` conformers. Pure value types — no `import UIKit`, no `import AppKit`. Both work identically on iOS+macOS.

16. **The on-screen `videoRect` is passed into the overlay as a parameter, not computed by the overlay.**
    *Rationale:* the player/preview view knows its own `videoRect` (via `playerLayer.videoRect` or layer geometry); the overlay shouldn't reach into the host view to compute it. Threading it through as a `CGRect` parameter keeps the overlay isolation-clean and lets the converter compose with either layer source.
    *M2 must:* `DetectionLayer(... videoRect: CGRect ...)`. `PlaybackSession.videoRect: AsyncStream<CGRect>` provides reactive updates. `CameraPreview` views derive `videoRect` from view bounds + the preview layer's gravity (or, if simpler, use the full view bounds for capture since the iOS preview is typically fullscreen).

17. **Capture-side mirroring lives on the `AVCaptureConnection`, NOT on the overlay or on view-layer transforms.**
    *Rationale:* `AVCaptureVideoPreviewLayer.connection?.isVideoMirrored` is the canonical front-camera flip seam — AVF handles it correctly, including for the coordinate converter (`layerRectConverted(...)` accounts for it automatically). The data-output's connection has its own `isVideoMirrored`, typically `false`, so Vision sees un-mirrored frames; the overlay then handles the mirror at render time via the converter.
    *M1 must:* `CaptureSession` sets `previewConnection.isVideoMirrored = (position == .front)`; `dataOutputConnection.isVideoMirrored = false` always. Document the separation in `CaptureSession`'s doc-comment.

18. **Rotation flows from `AVCaptureDevice.RotationCoordinator` to both the preview connection and the data-output connection independently.**
    *Rationale:* AVCam pattern; sibling decision 17. `RotationCoordinator` exposes two angles — `videoRotationAngleForHorizonLevelPreview` (what the user wants to see) and `videoRotationAngleForHorizonLevelCapture` (what Vision needs as input orientation). They can differ; both apply to their respective connection.
    *M1 must:* `CaptureSession` observes both `RotationCoordinator` properties and applies each to the right connection. No `UIDevice.current.orientation` anywhere (already a sibling/M0 ban).

### Public surface

19. **`CameraPreview` is iOS-only and lives in `IrisCapture`.**
    *Rationale:* macOS has no capture per platform baseline. `IrisCapture` is the iOS-only module; `CameraPreview` is its public preview view. macOS consumers don't import `IrisCapture`.
    *M1 must:* `CameraPreview` declared in `IrisCapture`. No `#if os(iOS)` guard in the *file* (the whole target is iOS-only). The type does not exist on macOS at all — apps importing `IrisCapture` on macOS will fail to link, which is the right failure.

20. **`PlayerView` is iOS+macOS in `IrisPlayback`, with a single `View` public type backed by platform-bridged hosts.**
    *Rationale:* the goal is one public type the app composes with `ZStack { PlayerView; DetectionLayer }` on both platforms. The implementation forks (`UIViewRepresentable` iOS, `NSViewRepresentable` macOS) inside the `body`; the public surface does not.
    *M3 must:* `public struct PlayerView: View` with `body` that conditionally selects `PlayerHostiOS` or `PlayerHostMac`. Both hosts are `internal`.

21. **`DetectionLayer` is iOS+macOS in `IrisOverlay`, with a single public type. The `==`/`Equatable` trick for `UIViewRepresentable` / `NSViewRepresentable` is **internal** to `CameraPreview` / `PlayerView`; `DetectionLayer` is pure SwiftUI and doesn't need it.**
    *Rationale:* the `==` trick prevents host-view rebuild thrash on Representable types only; `DetectionLayer` is a regular `View` whose body is `TimelineView { Canvas { … } }`, no Representable, no thrash.
    *M2 must:* `DetectionLayer: View` (not Representable). No `==` override.

22. **`@preconcurrency import AVFoundation` is allowed in `PreviewView.swift`, `PlayerHostUIView.swift`, `PlayerHostNSView.swift`, and the concrete `AVCapturePreviewSource.swift` / `AVPlaybackPreviewSource.swift` files only.**
    *Rationale:* extending sibling decision 18. The display-side AVF touch surface is the host views (which must reference `AVCaptureVideoPreviewLayer` / `AVPlayerLayer`) and the concrete `PreviewSource` types. Public files (`CameraPreview.swift`, `PlayerView.swift`, `DetectionLayer.swift`, `PreviewSource.swift`, `PlaybackPreviewSource.swift`) get a plain `import AVFoundation` only if they actually need `AVCaptureSession` / `AVPlayer` types in non-isolated signatures — and most don't.
    *M1/M2/M3 must:* code review enforcement. Audit every file touching AVF; classify as "internal AVF-touching impl" (preconcurrency OK) or "public API" (no preconcurrency).

23. **No `AVPlayerItemVideoOutput` anywhere in the display pipeline.**
    *Rationale:* reaffirms sibling's anti-pattern list. The display path is `AVPlayer` + `AVPlayerLayer`; the analysis path is `AVAssetReader`. There is no third path. `AVPlayerItemVideoOutput` is the wart PRVisionSpike has; Iris explicitly does not.
    *M3 must:* code-review block. The phrase `AVPlayerItemVideoOutput` should not appear in `IrisPlayback` source.

24. **No `AVSynchronizedLayer` anywhere in `IrisOverlay`.**
    *Rationale:* doesn't work with `AVCaptureSession`; would create a forked overlay pipeline (`AVSynchronizedLayer` for playback, something else for capture); violates the cross-source overlay principle.
    *M2 must:* code-review block.

25. **No Combine in `IrisPlayback` or `IrisOverlay`.**
    *Rationale:* reaffirms sibling decision 19 for the display side. `@Observable` (`ResultStore`) replaces `@Published`. `AsyncStream<CMTime>` replaces `Publisher<CMTime>` for periodic time. KVO on `AVPlayerLayer.videoRect` happens, but it's converted to an `AsyncStream<CGRect>` at the seam — no `AnyPublisher` leakage.
    *M2/M3 must:* zero `import Combine`. KVO observation wrapped in `AsyncStream { continuation in let obs = layer.observe(\.videoRect, ...) { … } continuation.onTermination = { obs.invalidate() } }`.

### Cross-cutting

26. **The `videoRect` for the capture preview is the view's bounds.**
    *Rationale:* `AVCaptureVideoPreviewLayer.layerRectConverted(fromMetadataOutputRect:)` does the letterbox math internally; the converter passes view bounds + a normalized rect and AVF returns the correct on-screen rect. No need for Iris to compute `videoRect` for capture separately.
    *M1+M2 must:* `PreviewLayerConverter.viewRect(forNormalized:in:)` calls `previewLayer.layerRectConverted(fromMetadataOutputRect:)` — taking `in:` as the view bounds. This means `PreviewLayerConverter` needs a reference to the layer; pass it in at init time.

27. **For playback, the `videoRect` is `AVPlayerLayer.videoRect`, observed via KVO and surfaced as an `AsyncStream<CGRect>` on `PlaybackSession`.**
    *Rationale:* `playerLayer.videoRect` is the post-aspect-fit on-screen rect, the property the overlay's converter needs. Reading it once is fine; reading it reactively (when the user resizes / rotates) requires KVO. Wrapping KVO in an `AsyncStream` keeps the public API Combine-free.
    *M3 must:* `PlaybackSession.videoRect: AsyncStream<CGRect>` backed by `playerLayer.observe(\.videoRect, options: [.initial, .new]) { … continuation.yield(…) }` from inside the host view's `@MainActor` setup.

---

## Type sketches

The final, locked Swift signatures. M1+M2+M3 land these (or close cousins; field-by-field changes welcome, structural changes need a new block).

### `CameraPreview` (IrisCapture, iOS-only)

```swift
import SwiftUI
@preconcurrency import AVFoundation

public struct CameraPreview: UIViewRepresentable {
    public let source: PreviewSource

    public init(source: PreviewSource) { self.source = source }

    public func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        source.connect(to: view)
        return view
    }

    public func updateUIView(_ uiView: PreviewView, context: Context) { /* no-op */ }

    /// Suppress SwiftUI's per-state-change UIView rebuild. The source identity is
    /// stable for the session's lifetime, so equality on source identity is safe.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        ObjectIdentifier(lhs.source as AnyObject) == ObjectIdentifier(rhs.source as AnyObject)
    }
}

/// Internal. UIKit host whose backing layer IS the preview layer.
final class PreviewView: UIView, PreviewTarget {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    func setSession(_ session: AVCaptureSession) {
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspect
    }
}

// PreviewSource / PreviewTarget locked by sibling decision 15 — copied here for completeness:
//   public protocol PreviewSource: Sendable { func connect(to target: PreviewTarget) }
//   @MainActor public protocol PreviewTarget { func setSession(_ session: AVCaptureSession) }
```

### `PlayerView` + bridges (IrisPlayback, iOS + macOS)

```swift
import SwiftUI
@preconcurrency import AVFoundation

public struct PlayerView: View {
    public let source: PlaybackPreviewSource

    public init(source: PlaybackPreviewSource) { self.source = source }

    public var body: some View {
        #if os(iOS)
        PlayerHostiOS(source: source)
        #elseif os(macOS)
        PlayerHostMac(source: source)
        #endif
    }
}

public protocol PlaybackPreviewSource: Sendable {
    func connect(to target: PlaybackPreviewTarget)
}

@MainActor public protocol PlaybackPreviewTarget {
    func setPlayer(_ player: AVPlayer)
}

#if os(iOS)
struct PlayerHostiOS: UIViewRepresentable {
    let source: PlaybackPreviewSource
    func makeUIView(context: Context) -> PlayerHostUIView {
        let view = PlayerHostUIView()
        source.connect(to: view)
        return view
    }
    func updateUIView(_ uiView: PlayerHostUIView, context: Context) { /* no-op */ }
    static func == (lhs: Self, rhs: Self) -> Bool {
        ObjectIdentifier(lhs.source as AnyObject) == ObjectIdentifier(rhs.source as AnyObject)
    }
}

final class PlayerHostUIView: UIView, PlaybackPreviewTarget {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    func setPlayer(_ player: AVPlayer) {
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
    }
}
#endif

#if os(macOS)
struct PlayerHostMac: NSViewRepresentable {
    let source: PlaybackPreviewSource
    func makeNSView(context: Context) -> PlayerHostNSView {
        let view = PlayerHostNSView()
        source.connect(to: view)
        return view
    }
    func updateNSView(_ nsView: PlayerHostNSView, context: Context) { /* no-op */ }
    static func == (lhs: Self, rhs: Self) -> Bool {
        ObjectIdentifier(lhs.source as AnyObject) == ObjectIdentifier(rhs.source as AnyObject)
    }
}

final class PlayerHostNSView: NSView, PlaybackPreviewTarget {
    private let avPlayerLayer = AVPlayerLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = avPlayerLayer
        avPlayerLayer.videoGravity = .resizeAspect
    }
    required init?(coder: NSCoder) { fatalError("not coded") }
    func setPlayer(_ player: AVPlayer) {
        avPlayerLayer.player = player
    }
}
#endif
```

### `DetectionLayer` + result store (IrisOverlay, iOS + macOS)

```swift
import SwiftUI
import CoreMedia

public struct DetectionLayer: View {
    public let resultStore: ResultStore
    public let videoRect: CGRect
    public let displayTime: CMTime
    public let style: OverlayStyle
    public let converter: any NormalizedGeometryConverting

    public init(resultStore: ResultStore,
                videoRect: CGRect,
                displayTime: CMTime,
                style: OverlayStyle = .default,
                converter: any NormalizedGeometryConverting = PlayerLayerConverter()) {
        self.resultStore = resultStore
        self.videoRect = videoRect
        self.displayTime = displayTime
        self.style = style
        self.converter = converter
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0/60)) { _ in
            let detections = resultStore.lookup(at: displayTime)
            Canvas { context, _ in
                for detection in detections {
                    let rect = converter.viewRect(forNormalized: detection.normalizedBox,
                                                  in: videoRect)
                    context.stroke(Path(rect),
                                   with: .color(style.color(for: detection.label)),
                                   lineWidth: style.strokeWidth)
                    // labels, keypoints, masks — same pattern
                }
            }
            .drawingGroup()
            .allowsHitTesting(false)
        }
    }
}

@MainActor
@Observable
public final class ResultStore {
    private(set) public var capacity: Int
    private var buffer: [TimestampedDetections] = []
    public var liveStalenessThreshold: CMTime = CMTime(value: 500, timescale: 1000)
    public var playbackStalenessThreshold: CMTime = CMTime(value: 2, timescale: 1)

    public init(capacity: Int = 30) { self.capacity = capacity }

    public func append(_ result: TimestampedDetections) {
        let idx = buffer.firstIndex(where: { $0.timestamp > result.timestamp }) ?? buffer.endIndex
        buffer.insert(result, at: idx)
        if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }
    }

    public func clear() { buffer.removeAll(keepingCapacity: true) }

    /// Returns the most-recent result whose timestamp is ≤ displayTime, or [] if none
    /// (or if the most recent result is stale beyond the staleness threshold).
    public func lookup(at displayTime: CMTime, stale: CMTime? = nil) -> [Detection] {
        guard !buffer.isEmpty else { return [] }
        // Binary-search insertion index
        var lo = 0, hi = buffer.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if buffer[mid].timestamp <= displayTime { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0 else { return [] }
        let candidate = buffer[lo - 1]
        let threshold = stale ?? liveStalenessThreshold
        if displayTime - candidate.timestamp > threshold { return [] }
        return candidate.detections
    }
}

public struct TimestampedDetections: Sendable, Hashable {
    public let timestamp: CMTime
    public let detections: [Detection]
    public init(timestamp: CMTime, detections: [Detection]) {
        self.timestamp = timestamp
        self.detections = detections
    }
}

public protocol NormalizedGeometryConverting: Sendable {
    /// Vision-normalized (bottom-left-origin, 0…1) → SwiftUI top-left-origin pixel space.
    func viewRect(forNormalized rect: CGRect, in videoRect: CGRect) -> CGRect
    func viewPoint(forNormalized point: CGPoint, in videoRect: CGRect) -> CGPoint
}

public struct PreviewLayerConverter: NormalizedGeometryConverting {
    // Holds an unowned reference to the AVCaptureVideoPreviewLayer — set at view-host time.
    // Implementation delegates to layer.layerRectConverted(fromMetadataOutputRect:).
}

public struct PlayerLayerConverter: NormalizedGeometryConverting {
    public init() {}
    // Aspect-fit math against videoRect — Sportvision's centralized Y-flip + display rect.
    public func viewRect(forNormalized rect: CGRect, in videoRect: CGRect) -> CGRect {
        CGRect(x: videoRect.origin.x + rect.origin.x * videoRect.width,
               y: videoRect.origin.y + (1 - rect.origin.y - rect.height) * videoRect.height,
               width: rect.width * videoRect.width,
               height: rect.height * videoRect.height)
    }
    public func viewPoint(forNormalized point: CGPoint, in videoRect: CGRect) -> CGPoint {
        CGPoint(x: videoRect.origin.x + point.x * videoRect.width,
                y: videoRect.origin.y + (1 - point.y) * videoRect.height)
    }
}
```

### `PlaybackSession` display-side additions (extending sibling's actor)

```swift
extension PlaybackSession {
    /// nonisolated opening for the SwiftUI PlayerView; symmetric to CaptureSession.previewSource.
    public nonisolated var previewSource: PlaybackPreviewSource { /* held as stored nonisolated let */ }

    /// On-screen video rect, accounting for aspect-fit letterbox. Observable.
    /// Backed by KVO on AVPlayerLayer.videoRect, wrapped in AsyncStream.
    public var videoRect: AsyncStream<CGRect> { get }

    /// Current playback time, host-rate (60 Hz). Backed by addPeriodicTimeObserver.
    public var currentTime: AsyncStream<CMTime> { get }

    /// Emitted just before seek(to:) tears down the reader, so consumers can clear their
    /// result stores.
    public var willSeek: AsyncStream<CMTime> { get }
}
```

---

## M1 / M2 / M3 scope additions

Concrete bullets to fold into the milestone plans.

### M1 (capture preview)

1. **Ship `PreviewView`, `CameraPreview`, `AVCapturePreviewSource` + the `PreviewSource`/`PreviewTarget` protocols together.** None work alone.
2. **`PreviewView.layerClass` override** — not `addSublayer`. Cheaper, no geometry plumbing.
3. **`CameraPreview` `Equatable` `==` returns `ObjectIdentifier`-based equality on `source`** — MijickCamera's anti-thrash pattern.
4. **`previewLayer.videoGravity = .resizeAspect`** at session-attach time.
5. **Mirroring split: preview connection `isVideoMirrored` follows camera position; data-output connection `isVideoMirrored = false` always.** Document the split.
6. **`#Preview` for `CameraPreview`** using a `MockPreviewSource` that wraps a no-op session — establishes that the SwiftUI surface renders without a camera.

### M2 (overlay)

1. **Ship `DetectionLayer`, `ResultStore`, `TimestampedDetections`, `NormalizedGeometryConverting`, `PreviewLayerConverter`, `PlayerLayerConverter`, `OverlayStyle` together.**
2. **Binary-search lookup in `ResultStore.lookup(at:)`** — O(log n), not linear scan.
3. **Staleness check inside `lookup`** — `displayTime - candidate.timestamp > threshold` returns `[]`.
4. **`.drawingGroup()` and `.allowsHitTesting(false)` on the `Canvas`**, no knobs.
5. **`TimelineView(.animation(minimumInterval: 1.0/60))` wraps the `Canvas`.**
6. **`PlayerLayerConverter` is the default `converter` argument** — `PreviewLayerConverter` overrides for capture.
7. **Fixture-based test in M2**: a known `[TimestampedDetections]` + a known `CMTime` + an expected `[Detection]` lookup result. Pure value-type test, no SwiftUI rendering needed.
8. **`#Preview` cases for `DetectionLayer`** with synthetic detections and a static `videoRect` — establishes the visual-preview discipline (CLAUDE.md "favorite pattern" — static visual previews are higher leverage than running the full app).
9. **Static HTML preview** of the overlay's box rendering at various sizes — co-located with the module, lets the user spot-check colors/strokes/letterbox math at a glance without a build.

### M3 (playback, first macOS target)

1. **Ship `PlayerView`, `PlayerHostiOS`, `PlayerHostNSView`, `PlaybackPreviewSource`, `PlaybackPreviewTarget`, `AVPlaybackPreviewSource` together.**
2. **`PlayerHostUIView.layerClass = AVPlayerLayer.self`** — same pattern as preview. `PlayerHostNSView` uses `wantsLayer + layer = AVPlayerLayer()`.
3. **`PlaybackSession.videoRect: AsyncStream<CGRect>`** backed by KVO on the player layer.
4. **`PlaybackSession.currentTime: AsyncStream<CMTime>`** backed by `addPeriodicTimeObserver` at 60 Hz.
5. **`PlaybackSession.willSeek: AsyncStream<CMTime>`** emitted just before reader rebuild; consumers `for await time in session.willSeek { resultStore.clear() }`.
6. **macOS `#Preview` for `PlayerView`** with a bundled fixture asset — establishes macOS parity from day one (per `BRIEF.md` working norms).
7. **End-to-end macOS smoke test**: load a fixture `.mov`, render `PlayerView` + a hard-coded `DetectionLayer`, assert at least one tick of the `Canvas` redraws. Real fixture, no mocks.

---

## Anti-patterns M1+ must avoid

Sharpened to the display side:

- **Tapping `Source.frames` for display rendering.** The single load-bearing prohibition. Display reads from `AVCaptureVideoPreviewLayer` (capture) or `AVPlayerLayer` (playback); `Source.frames` is exclusively for the detector. Code review block.
- **Calling `AVPlayer.currentTime()` per `Canvas.draw` invocation in a tight loop.** Polling property reads on AVF objects from a `TimelineView` closure can be expensive and pin the main thread. Use `addPeriodicTimeObserver` instead — push the value through `@State`, read `@State` in the closure.
- **`AVPlayerItemVideoOutput` anywhere.** Reaffirms sibling's ban — there is no third frame path.
- **`AVSynchronizedLayer` anywhere.** Capture-incompatible; would fragment the overlay design.
- **`AVPlayerView` (AVKit) for the macOS playback host.** Ships its own controls, doesn't expose `videoRect`, fights `IrisTuning`'s future scrubber.
- **SwiftUI's `VideoPlayer` for the playback display.** Same issue: ships controls; no `videoRect` hook.
- **`UIBezierPath` / `NSBezierPath` in the overlay.** M0 ban; redundant here for emphasis.
- **`UIDevice.current.orientation` in coordinate math.** M0 ban; redundant here for emphasis. The overlay never reads global device state.
- **`#if os(iOS)` in `DetectionLayer.swift`.** The overlay is pure SwiftUI; platform guards belong only in `PlayerView`'s host views.
- **Reading `playerLayer.videoRect` on a non-MainActor.** It's a CALayer property; CALayer is not Sendable; access must be `@MainActor`. The `AsyncStream<CGRect>` wrapper enforces this — KVO observation reads on MainActor and yields a plain `CGRect` value across actor boundaries.
- **Storing detection results without a timestamp.** `ResultStore.append` only takes `TimestampedDetections`; there's no overload that defaults the timestamp. Detection results without a source-frame timestamp cannot be synchronized.
- **Per-detection `View` in the SwiftUI hierarchy.** Don't write `ForEach(detections) { BoxView($0) }`. Use a single `Canvas` that draws all detections in one pass — SwiftUI's view-tree cost is non-trivial with hundreds of boxes per frame.
- **`Task { … }` per detection result inside `ResultStore.append`.** Synchronous insert; no actor hop. Pattern matches sibling decision 20 (no per-frame `Task` spawn).
- **Combine in `IrisOverlay` or `IrisPlayback`.** Reaffirms sibling decision 19; KVO wrapped in `AsyncStream`, not `AnyPublisher`.
- **`@preconcurrency import AVFoundation` in public-surface files.** `CameraPreview.swift`, `PlayerView.swift`, `DetectionLayer.swift`, the protocol files — none of these need preconcurrency. It's gated to the host views and concrete `*PreviewSource` files.

---

## Open items deferred

Not locked here; needs follow-on before they become relevant:

- **Ring-buffer capacity tuning** (`30` is M2's default; M3 playback may want hundreds for long assets). The API doesn't change; only the eviction policy does.
- **Detector latency telemetry exposed on `ResultStore`.** Trivial to add (`observedLatency: CMTime` computed from `displayTime - lookup.timestamp`); deferred to M4 (`IrisTuning` may want to display it).
- **`PreviewSource.connect(to:)` re-connection semantics.** Idempotent in practice; spec a test in M1.
- **macOS scrub UI.** Lives in `IrisTuning`; uses `DetectionLayer`'s `displayTime` binding as the seam. Out of scope for this block.
- **Multi-subscriber broadcast on `Source.frames`.** Sibling open item; display-pipeline architecture is agnostic. Defer to M5 with `IrisDataset`.
- **Forward prediction for live-capture overlay.** Domain choice; lives in downstream apps. Iris ships honest "best-effort, lagged" overlays.
- **HDR / EDR rendering.** WWDC22 covers EDR rendering with AVFoundation + Metal; if Iris ever wants HDR overlays, the `AVPlayerLayer` path supports EDR natively, and `Canvas` rendering in EDR is a separate question. Out of scope for M1-M3.
- **Picture-in-Picture for playback view.** Both `AVPlayerLayer` and `AVSampleBufferDisplayLayer` support PiP via `AVPictureInPictureController.ContentSource`. Out of scope until an app needs it.

---

*This file is scoped to display-pipeline architecture decisions for Iris's display side (preview, player, overlay, frame-sync). Capture/playback source-side decisions live in the sibling [`../runtime-pipeline-architecture/RECOMMENDATIONS.md`](../runtime-pipeline-architecture/RECOMMENDATIONS.md). Detector internals, dataset sinks, sidecar formats, tuning UI, and package layout each have their own decision surfaces — see `BRIEF.md` and the other exploration recommendations.*
