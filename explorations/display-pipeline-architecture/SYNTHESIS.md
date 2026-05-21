# Display-pipeline architecture — synthesis

**Read date:** 2026-05-20
**Scope:** display side of Iris — how the user *sees* the live camera feed (iOS) or playing asset (iOS+macOS) on screen, how detection overlays layer on top, and how detector results stay frame-synchronized with what's visible. Detector internals, `Source`/`Frame`/`CaptureSession` shape (locked by the sibling block), dataset capture, tuning UI, sidecar format, Foundation Models, and package layout are explicitly out.

**Inputs:** the sibling [`../runtime-pipeline-architecture/SYNTHESIS.md`](../runtime-pipeline-architecture/SYNTHESIS.md) + [`../runtime-pipeline-architecture/RECOMMENDATIONS.md`](../runtime-pipeline-architecture/RECOMMENDATIONS.md) (load-bearing — every display decision here composes with those locked decisions). M0 verdicts in [`../prior-projects/SYNTHESIS.md`](../prior-projects/SYNTHESIS.md) (Q5 macOS overlay parity, especially) and [`../prior-projects/RECOMMENDATIONS.md`](../prior-projects/RECOMMENDATIONS.md). Sportvision is the proof-of-concept for cross-platform `Canvas` overlay (`../prior-projects/sportvision.md`). PRVisionSpike (`../prior-projects/PRVisionSpike.md`) for the player+asset-reader coexistence pattern. Apple AVCam (`../swift-ecosystem/apple-avcam.md`) for `PreviewSource`/`PreviewTarget`. Targeted lookups on `AVCaptureVideoPreviewLayer`, `AVPlayerLayer` + `videoRect`, `AVSampleBufferDisplayLayer` (when *not* to use it), `AVSynchronizedLayer` (and why it's not the right tool for Iris), `AVPlayerItemVideoOutput` (and why it's banned by sibling decision 27, anti-patterns).

---

## 1. Context

The sibling block locked the **data plane**: how a frame physically gets out of `AVCaptureSession` and `AVAssetReader` into an `AsyncStream<Frame>` with `.bufferingNewest(1)` back-pressure, single-consumer, source-agnostic downstream. What it did *not* address — and the user surfaced as a gap — was the **display plane**: when the user is looking at the screen, what's actually painting pixels, and how do detection results land on top of those pixels in a way that doesn't lag the live subject?

The two planes are *parallel* and *coupled at one point* (the overlay). The data plane's job is to deliver `Frame`s to a detector. The display plane's job is to put pixels on screen and let the consumer paint annotations on top. They share **time** (`Frame.timestamp`, `AVPlayer.currentTime`, host clock) but they do not share **pixels** — the user sees pixels rendered by AVF-native hardware paths (`AVCaptureVideoPreviewLayer` / `AVPlayerLayer`), *not* by repainting `Frame.pixelBuffer` through Iris's code.

This document locks that two-plane shape so M1 (capture preview), M3 (playback preview, first macOS target), and M2 (overlay) plan against a single picture instead of relitigating it.

What this **resolves**:
- The playback display surface — `AVPlayer` + `AVPlayerLayer`, not `AVSampleBufferDisplayLayer`.
- Fan-out — display does **not** tap `Source`; `Source` stays single-consumer.
- Overlay layer — pure SwiftUI `Canvas` over a UIKit/AppKit-bridged display view, no `AVSynchronizedLayer`, no `AVPlayerItemVideoOutput`.
- Frame-sync model — timestamp-tagged detection results + a small ring buffer keyed by `Frame.timestamp`; the overlay reads display time at draw time and picks the most-recent result `≤ display_time`.
- Public SwiftUI surface — `CameraPreview` (iOS), `PlayerView` (iOS+macOS), `DetectionLayer` overlay container. Concrete signatures land in §9.

What this does **not** resolve: gesture handling on the player (scrub bar UI is `IrisTuning`/app-level), per-detector style (color, stroke width — `IrisOverlay` styling block), audio.

---

## 2. The two parallel paths

The single most important diagram in this block:

```
                              ┌──────────────────────────────────────┐
                              │       AVCaptureSession (iOS)         │
                              │   or   AVPlayer + AVPlayerItem (any) │
                              └─────────────────┬────────────────────┘
                                                │
                  ┌─────────────────────────────┴─────────────────────────────┐
                  │                                                           │
                  │ DISPLAY PATH                              ANALYSIS PATH   │
                  │ (AVF-native, hardware)                    (Iris-owned)    │
                  │                                                           │
                  ▼                                                           ▼
   ┌──────────────────────────────┐                       ┌───────────────────────────────┐
   │ AVCaptureVideoPreviewLayer   │                       │ AVCaptureVideoDataOutput      │
   │   (iOS capture)              │                       │   delegate ──► AsyncStream    │
   │ OR                           │                       │ OR                            │
   │ AVPlayerLayer                │                       │ AVAssetReader                 │
   │   (iOS+macOS playback)       │                       │   pull-loop  ──► AsyncStream  │
   │                              │                       │                               │
   │ → owned by AVF               │                       │ → owned by Iris (`Source`)    │
   │ → its own decoder/clock      │                       │ → .bufferingNewest(1)         │
   │ → its own video memory       │                       │ → single consumer             │
   └────────────┬─────────────────┘                       └──────────────┬────────────────┘
                │                                                        │
                │  paints pixels                                         │  yields Frame
                │  (no Iris code on the                                  │  to consumer Task
                │   render hot path)                                     │
                ▼                                                        ▼
   ┌──────────────────────────────┐                       ┌───────────────────────────────┐
   │ UIView / NSView host         │                       │ Detector                      │
   │   (UIViewRepresentable /     │                       │   .detect(frame)              │
   │    NSViewRepresentable)      │                       │   → [Detection]               │
   └────────────┬─────────────────┘                       └──────────────┬────────────────┘
                │                                                        │
                │                                                        │
                │                  ┌───────────────────────┐             │
                └─────────────────►│   ZStack: video on    │◄────────────┘
                                   │   bottom, SwiftUI     │   results tagged with
                                   │   Canvas overlay      │   Frame.timestamp,
                                   │   on top              │   stored in a ring
                                   │                       │   buffer keyed by
                                   │   reads display time, │   timestamp
                                   │   picks last result   │
                                   │   ≤ display_time      │
                                   └───────────────────────┘
                                          ▲       ▲
                                          │       │
                                       reconvergence
                                       (the overlay)
```

**Key invariants visible in this diagram:**

1. The display path **does not flow through `Source`**. `AVCaptureVideoPreviewLayer` is attached to the `AVCaptureSession` directly as a *separate output* — it's a CALayer with its own video memory and its own clock, fed by AVF internally, not by anything Iris code touches. Same with `AVPlayerLayer`: it's driven by the `AVPlayer`'s own decode/display loop, not by `Frame`s flowing through Iris.

2. The analysis path **does not paint pixels**. The `Frame`s that flow through `Source` exist for the detector. They are *not* the source of the pixels the user sees. The display is faster (60 fps, hardware) and more reliable than re-rendering `Frame`s in Iris ever could be.

3. The two paths **share a time domain** (`CMTime` PTS, host clock), not a memory domain. That's how reconvergence in the overlay works: the overlay reads display-side time (`AVPlayer.currentTime()`, or simply "now" for live capture) and picks a detection result whose `Frame.timestamp` is closest to it.

4. **The overlay sits on top of, not inside, the display layer.** SwiftUI `ZStack { PlayerView; DetectionLayer }`. The overlay never participates in the video decode/display pipeline. This is what makes macOS parity essentially free — neither the player view nor the overlay needs to know what the other one is doing.

This is the answer to the "fan-out" question. **There is no fan-out of `Source`.** The two consumers (display and detector) tap *different* AVF surfaces of the same session. Display gets its frames from the layer attached to the session (capture) or from the player attached to the asset (playback); the detector gets its frames from the data output / asset reader. Both run in parallel, on different hardware paths, with their own buffering. `Source.bufferingNewest(1)` stays intact because `Source` has exactly one downstream consumer: the detector.

---

## 3. Capture preview

**Surface:** `AVCaptureVideoPreviewLayer`. iOS-only by Iris's platform baseline (macOS has no camera capture per `CLAUDE.md` and the BRIEF). The preview layer is the canonical, hardware-accelerated, AVF-native preview for `AVCaptureSession`; no other choice is reasonable.

### Ownership

The preview layer is **owned by a `UIView`**, not by Iris's `CaptureSession` actor. The actor never holds a `CALayer` reference. Instead it vends a `nonisolated let previewSource: PreviewSource` (Apple AVCam pattern, sibling decision 15) — a small `Sendable` protocol that lets a SwiftUI view, on `@MainActor`, ask to be wired up to the underlying `AVCaptureSession` for preview purposes.

The mechanism is a two-protocol indirection:

```swift
// PreviewSource lives on the actor as a nonisolated let — Sendable.
public protocol PreviewSource: Sendable {
    func connect(to target: PreviewTarget)
}

// PreviewTarget lives on @MainActor — the SwiftUI view's UIView host conforms.
@MainActor public protocol PreviewTarget {
    func setSession(_ session: AVCaptureSession)
}
```

The `AVCapturePreviewSource` (Iris's concrete `PreviewSource`) holds a weak reference to the `AVCaptureSession` and, when `connect(to:)` is called, hops to `@MainActor` and calls `target.setSession(session)`. The target — a `PreviewView: UIView` whose `layerClass` is overridden to `AVCaptureVideoPreviewLayer.self` — assigns the session to its layer. That's the one and only place an `AVCaptureSession` reference crosses out of the actor wall, and it crosses to `@MainActor`, not to any other isolation domain.

This pattern is verbatim from Apple AVCam (`apple-avcam.md` §Capture entrypoint). The reason for the indirection is exactly the leak Iris must avoid: never put an `AVCaptureSession` in a public type a consumer holds, because that drags the AVF type system into every test and view that touches the value. `PreviewSource` is `Sendable` and has no AVF in its public signature; only the *concrete* `AVCapturePreviewSource` (internal) imports AVFoundation.

### The `UIViewRepresentable` wrap

The public SwiftUI view:

```swift
public struct CameraPreview: UIViewRepresentable {
    public let source: PreviewSource

    public init(source: PreviewSource) { self.source = source }

    public func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        source.connect(to: view)
        return view
    }

    public func updateUIView(_ uiView: PreviewView, context: Context) { /* no-op */ }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        // MijickCamera trick: prevent SwiftUI from rebuilding the UIView on every parent state change.
        // The PreviewSource identity is stable for the session's lifetime, so equal is safe.
        ObjectIdentifier(lhs.source as AnyObject) == ObjectIdentifier(rhs.source as AnyObject)
    }
}

final class PreviewView: UIView, PreviewTarget {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    func setSession(_ session: AVCaptureSession) {
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspect       // letterbox; matches what the overlay's geometry expects
    }
}
```

The `Equatable` conformance with `static func == { … }` is borrowed from MijickCamera (`../swift-ecosystem/mijick-camera.md` §"Carry forward into Iris"). It prevents `makeUIView` thrash when SwiftUI rebuilds the parent view tree — the view's identity is the `PreviewSource`'s, not anything else.

The `layerClass` override is the textbook iOS pattern for preview layers (also surfaced in the search results: every SwiftUI-AVPlayer tutorial does the same trick for `AVPlayerLayer`). The view *is* the preview layer, not a host containing a preview layer; this is cheaper, has no sublayer geometry to manage, and lays out automatically.

### Mirroring and rotation

Both come from the **`AVCaptureConnection`** attached to the preview layer's input, *not* from layer transforms in the SwiftUI view. The sibling's `AVCaptureDevice.RotationCoordinator` (sibling decision 17) drives both:

- The preview connection (`previewLayer.connection?.videoRotationAngle = …`)
- The data output's connection (used to tag `Frame.orientation`)

Both observe the same `rotationCoordinator.videoRotationAngleForHorizonLevelPreview` (preview) or `…ForHorizonLevelCapture` (data). The two angles can differ (the preview angle is what the user expects to see for framing; the capture angle is what Vision wants for its input orientation) — `RotationCoordinator` exposes both, and Iris's `CaptureSession` wires them to their respective connections without any orientation math in app code.

Mirroring (front-camera flip) is also a connection-level property: `previewLayer.connection?.isVideoMirrored = true` for front. The data-output connection's `isVideoMirrored` is set *independently* — typically `false`, because Vision expects un-mirrored coordinates and the overlay's coordinate converter (§8) handles the mirror at render time, not at capture time.

This is the same separation `action-and-vision` and AVCam apply: orientation/mirroring of *what the user sees* and orientation/mirroring of *what the model analyzes* are two different concerns, both centralized at the connection level, neither leaked into view code.

### macOS

`CameraPreview` is **iOS-only**. The platform baseline (`CLAUDE.md`, `BRIEF.md`) is unambiguous: macOS has no capture in Iris. The `CameraPreview` type lives in `IrisCapture` (iOS-only target). macOS consumers see `IrisCapture` as not-imported; they cannot accidentally call `CameraPreview` because the type doesn't exist on their platform.

(`AVCaptureVideoPreviewLayer` actually has macOS support in AVFoundation — but Iris is not exposing capture on macOS at all, so the layer's macOS availability is moot.)

---

## 4. Playback display

**Surface choice: `AVPlayer` + `AVPlayerLayer`.** Not `AVSampleBufferDisplayLayer`, not manual Metal/CI compositing, not `VideoPlayer` (the SwiftUI shorthand). The rationale is below.

### Why `AVPlayer` and not `AVSampleBufferDisplayLayer`

`AVSampleBufferDisplayLayer` is the lower-level surface where *you* push `CMSampleBuffer`s and *you* own the pacing (via `controlTimebase` + `enqueue(_:)` + `flush()`). It exists for cases where you have a custom decode pipeline (network video, screen sharing, AR composition) and need to control timing at the buffer level. Iris is not that case:

- The asset on disk is a standard file (`.mov` / `.mp4`); `AVPlayer` decodes it natively, manages its own clock, handles seeking, scrubbing, rate changes, audio sync, and AirPlay — *all of which Iris would have to re-implement* on top of `AVSampleBufferDisplayLayer`.
- Iris's `PlaybackSession` already uses `AVAssetReader` to extract frames for the *analysis* path (sibling decision 12). That reader runs independently. We do not need `AVAssetReader`'s frames for *display* — we have `AVPlayer` for display, which is faster and gives us scrubber UI essentially for free.

The trade-off in numbers: `AVPlayer`+`AVPlayerLayer` is ~5 lines of setup; `AVSampleBufferDisplayLayer` would require porting a real-time pacer, a control timebase, a flush-on-seek mechanism, and audio sync — easily 200+ lines, all of which AVF already gives us. There is no Iris-shaped reason to take that on.

`AVSampleBufferDisplayLayer` is documented as preferred for "custom video pipelines that require direct manipulation of media samples" (WWDC21 PiP session; objc.io camera capture writeups). That's not us.

### Why not `VideoPlayer` (SwiftUI)

SwiftUI's `VideoPlayer` view (AVKit) is a great prebuilt option for simple playback with controls. Two reasons it's not the right choice here:

1. It ships **transport controls baked in** (play, pause, scrub bar, fullscreen). Iris's playback view is meant to underlay a detection overlay and possibly a custom timeline scrubber from `IrisTuning`. Hiding/replacing the built-in controls fights the API.
2. There's no portable hook to read the active video `videoRect` (the on-screen rect after aspect-fit letterboxing) from a `VideoPlayer`. The overlay needs that rect to compute its coordinate system. With `AVPlayerLayer` you get `playerLayer.videoRect` directly.

### Why not manual rendering

A Metal/CoreImage path that pulls `CVPixelBuffer`s from `AVPlayerItemVideoOutput` or `AVAssetReader` and renders them via a Metal pipeline is the maximum-control option. It's what a custom video editor or a heavily-filtered live preview needs. Iris does **not** need it:

- Iris does no per-frame filtering of the *displayed* video. Filters and effects are app-level concerns; the detection overlay is drawn on top, not into the video.
- The asset-reader path for analysis already exists (sibling decision 12). Doubling it with a second pull path for display would mean two readers on the same asset — wasteful and synchronization-hostile.

The sibling explicitly **bans `AVPlayerItemVideoOutput` from the design** (`../runtime-pipeline-architecture/RECOMMENDATIONS.md` §"Anti-patterns" — last bullet). That's a hard line: the playback frame-extraction path is `AVAssetReader`, full stop. Display gets `AVPlayer` and never participates in frame extraction.

### Ownership

`AVPlayer` is owned by `PlaybackSession` (sibling actor). The player is **created and destroyed alongside the session**: `init(url:)` builds an `AVPlayer(playerItem: AVPlayerItem(url:))`; `invalidate()` calls `player.replaceCurrentItem(with: nil)` and drops the reference. The session **does not vend the `AVPlayer` directly** to the SwiftUI view — same reasoning as capture: don't leak an AVF type through the public surface. Instead the session exposes a `PlaybackPreviewSource` (analogous to `PreviewSource` on capture):

```swift
public protocol PlaybackPreviewSource: Sendable {
    func connect(to target: PlaybackPreviewTarget)
}

@MainActor public protocol PlaybackPreviewTarget {
    func setPlayer(_ player: AVPlayer)
}
```

Same shape as capture: a `nonisolated let` opening in the actor wall, a `Sendable` source, a `@MainActor` target. The SwiftUI `PlayerView` conforms its private hosted view to `PlaybackPreviewTarget`; `setPlayer` assigns the player to the host's `AVPlayerLayer`.

This makes the public Iris API completely AVF-free even for playback: callers see `PlaybackSession`, `PlayerView`, `PlaybackPreviewSource`. `AVPlayer` lives behind the seam.

### iOS + macOS parity via platform-bridged views

The host view forks by platform. The fork is purely *implementation*; the public `PlayerView: View` type is shared.

```swift
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

#if os(iOS)
struct PlayerHostiOS: UIViewRepresentable {
    let source: PlaybackPreviewSource
    func makeUIView(context: Context) -> PlayerHostUIView {
        let view = PlayerHostUIView()
        source.connect(to: view)
        return view
    }
    func updateUIView(_ uiView: PlayerHostUIView, context: Context) {}
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
    func updateNSView(_ nsView: PlayerHostNSView, context: Context) {}
    static func == (lhs: Self, rhs: Self) -> Bool {
        ObjectIdentifier(lhs.source as AnyObject) == ObjectIdentifier(rhs.source as AnyObject)
    }
}

final class PlayerHostNSView: NSView, PlaybackPreviewTarget {
    private let playerLayer = AVPlayerLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = playerLayer                              // AppKit equivalent of layerClass override
        playerLayer.videoGravity = .resizeAspect
    }
    required init?(coder: NSCoder) { fatalError() }
    func setPlayer(_ player: AVPlayer) {
        playerLayer.player = player
    }
}
#endif
```

This is the **only** `#if os` fork in `IrisPlayback`'s public surface — and it's contained to two 25-line host view definitions. The `PlayerView` struct, the `PlaybackPreviewSource` protocol, the `PlaybackPreviewTarget` protocol, and `PlaybackSession` itself are all platform-agnostic. Sportvision proved this pattern works (`../prior-projects/sportvision.md` §"Where the platforms *do* diverge"). The cost of macOS parity is 25 lines of `NSViewRepresentable`.

Two reasons this isn't `AVPlayerView` (AVKit) on macOS, despite that being the more "native" choice:

1. `AVPlayerView` ships its own controls UI. We want a bare display surface for the overlay to sit on; the controls would either need to be hidden (`controlsStyle = .none`) or, if visible, would fight a custom scrubber from `IrisTuning`. Going to bare `AVPlayerLayer`-on-`NSView` matches what iOS does and keeps the public surface symmetric.
2. `AVPlayerView` doesn't expose a `videoRect` the way `AVPlayerLayer` does. The overlay needs that rect; using the layer directly gives it to us.

### The coexistence with `AVAssetReader`

This is the crucial point: **`AVPlayer` (display) and `AVAssetReader` (analysis) run in parallel on the same asset, with no shared state.**

```
                        ┌─────────────┐
                        │   URL       │
                        └──────┬──────┘
                               │
            ┌──────────────────┴───────────────────┐
            │                                      │
            ▼                                      ▼
   ┌──────────────────┐                  ┌───────────────────┐
   │ AVPlayerItem ────│─────►  AVPlayer │ AVAssetReader     │
   │                  │       drives    │   forward-only    │
   │ → AVPlayerLayer  │       display   │   yields Frames   │
   │   on screen      │                 │   via AsyncStream │
   └──────────────────┘                 └───────────────────┘
            │                                      │
            │                                      │
            ▼                                      ▼
        user sees pixels                  detector consumes
        at AVPlayer's pace                Frames at its pace
```

Both feed from the same asset (URL). They are *independent decoders*. The player handles seek, scrub, pause, rate change for the user. The reader handles forward-only pull for the detector. When the user scrubs, `AVPlayer` jumps; `PlaybackSession.seek(to:)` (sibling decision 12) cancels the reader task and rebuilds the reader at the new time. The two operations happen together in the actor (one method call); the user sees instantaneous video seek, and the analysis stream picks up at the new time. **The two paths never share frames** — they share the asset URL and the time the user requested.

PRVisionSpike has both modes coexisting (`../prior-projects/PRVisionSpike.md` §"Frame plumbing") — and the lesson there was specifically that the cleaner half is the asset-reader path; the display-link path is the wart. Iris adopts the *cleaner half* for analysis, and lets `AVPlayer` handle display (which PRVisionSpike also does, separately).

---

## 5. Fan-out architecture

This is the locked answer to the open question "does display tap `Source`?"

**No. Display does not consume `Source.frames`.** `Source` remains single-consumer (`.bufferingNewest(1)`, sibling decision 14). Display gets its pixels from a *different AVF surface* attached to the same session/asset.

```
Capture (iOS):
                  ┌──────────────────────┐
                  │  AVCaptureSession    │
                  └──────────┬───────────┘
                             │ (attached as two outputs)
              ┌──────────────┴──────────────┐
              ▼                             ▼
   AVCaptureVideoPreviewLayer    AVCaptureVideoDataOutput
   (display path)                (analysis path)
        │                             │
        │ pixels → screen             │ delegate → AsyncStream<Frame>
        ▼                             ▼
   PreviewView (UIView)         CaptureSession actor
        │                             │  .bufferingNewest(1)
        ▼                             ▼
   CameraPreview                source.frames →
   (SwiftUI)                    consumer Task → detector

Playback (iOS + macOS):
                  ┌──────────────────────┐
                  │   URL (.mov)         │
                  └──────────┬───────────┘
              ┌──────────────┴──────────────┐
              ▼                             ▼
   AVPlayer + AVPlayerItem        AVAssetReader
   (display path)                 (analysis path)
        │                             │
        │ pixels → screen             │ pull loop → AsyncStream<Frame>
        ▼                             ▼
   AVPlayerLayer               PlaybackSession actor
        │                             │  .bufferingNewest(1)
        ▼                             ▼
   PlayerHost(iOS/Mac)         source.frames →
   PlayerView (SwiftUI)        consumer Task → detector
```

The two paths share:
- **The session/asset.** One `AVCaptureSession` with two outputs attached; one asset URL with two decoders.
- **The time domain.** PTS / `CMTime` for playback; host clock + frame PTS for capture. Both paths emit times in the same domain. Reconvergence in the overlay uses this.

The two paths do **not** share:
- **Pixels.** Display pixels live in the AVF preview-layer / player-layer's own video memory. `Frame.pixelBuffer` is a separate `CVPixelBuffer`, sourced from the data output / asset reader, never the same buffer the preview layer is showing.
- **Buffering.** Preview/player has its own internal buffering; `Source` has `.bufferingNewest(1)`. They drop independently.
- **Pacing.** Preview renders at 60 Hz (or wherever ProMotion is); `Source` yields at the detector's pace.

**This is the answer that respects sibling's `.bufferingNewest(1)` contract trivially**: the contract is between `Source` and the *one* downstream consumer (the detector). Display isn't downstream of `Source`; it's a sibling output of the same root session/asset. No fan-out, no broadcast, no `[UUID: Continuation]` (the sibling's deferred follow-on remains deferred until M3 dataset capture wants a second listener).

### What happens when the analysis path falls behind

This is where the design pays off most visibly. Suppose the detector is running at 10 fps on a 60 fps capture. The data path drops frames silently (sibling §9: `alwaysDiscardsLateVideoFrames = true` + `.bufferingNewest(1)` belt-and-braces). The display path *does not drop frames* — the preview layer keeps rendering every captured frame at 60 fps because its decoder is independent of the data output's delegate queue.

**Result:** the user sees buttery 60 fps preview while the detector grinds at 10 fps. Detection boxes lag by ~100 ms (3-6 frames). That's the expected, designed-for behavior — and it's only achievable because the two paths are independent. If display tapped `Source`, the user would see a 10 fps preview every time the detector was slow, which is unacceptable UX.

### Where the rough edges are

Edge case 1 — **the detector wants to draw on a specific frame.** Example: "save this frame to disk because the user tapped 'capture'." That frame must come from the analysis path (`Source.frames`), not the display path, because the display path's `CVPixelBuffer` isn't exposed in any sensible Iris API. This is fine — `IrisDataset` is downstream of `Source` already (sibling §2 "consumer side, out of scope, sketched"). The user-visible question "what's on screen right now?" maps to "what's the most-recent `Frame` the consumer received?", which is exactly `.bufferingNewest(1)`'s most-recent value.

Edge case 2 — **a scrubber that wants to show "what does the detector see at this timestamp?"** This is M3 (playback) territory. The natural answer: `PlaybackSession.seek(to:)` already rebuilds the reader at the requested time; the next `Frame` from `Source` is at that timestamp. The display is at that timestamp too (because the player seeked). The frames align by *timestamp*, not by any direct connection.

Edge case 3 — **dataset capture wants a second listener.** Deferred to M5 (sibling §10 open item 2). Iris ships single-consumer in v0; when M5 lands, either `IrisDataset` listens *through* the same consumer Task that feeds the detector (recommended — one `for await` loop fans out to detector + dataset + overlay), or the `Source` protocol grows a multi-subscriber broadcast. Both options compose with this fan-out architecture trivially because neither involves display.

---

## 6. Overlay layer

**Locked choice: SwiftUI `Canvas` overlay in a `ZStack` over the player/preview view.**

Alternatives considered and rejected:

- **`AVSynchronizedLayer`.** It's a `CALayer` whose `CAAnimation`s are driven by an `AVPlayerItem`'s timing — when the player pauses, the layer's animations pause; when the player rewinds, they rewind. Genuinely elegant *for animations*. But it only works with `AVPlayerItem`, *not* with `AVCaptureSession` (search results confirm this: the layer takes an `AVPlayerItem` argument, no capture-session variant exists). That alone disqualifies it: an overlay design that works only on playback and not on capture violates Iris's "same overlay pipeline for live and playback" principle (BRIEF §"Design principles"). Beyond the platform fork, `AVSynchronizedLayer` shines for animations *expressed as CAAnimation* — `CABasicAnimation`, `CAKeyframeAnimation` etc. Detection overlays are not pre-baked animations; they are reactive renders of a `[Detection]` value that changes per-frame. Driving that via a synchronized layer would mean instantiating a CAAnimation per detection per frame, which is the wrong shape entirely.

- **Custom `CALayer` composition.** Build a `CALayer` tree (or `CAShapeLayer`s per detection) and update their geometries imperatively. Works on both iOS and macOS, full control. But: it's the opposite of SwiftUI-first. Every styling change (colors, labels, animations) requires layer plumbing, and the macOS/iOS forks proliferate. SportVision tried both and landed on SwiftUI `Canvas` (`../prior-projects/sportvision.md` §"Overlay coordinate-space handling"): pure `Canvas`, ~170 lines, zero `#if os`, runs identically on both platforms. We adopt that verbatim.

- **`UIBezierPath` / `NSBezierPath` in the overlay.** Rejected outright as an anti-pattern (M0 verdict, `../prior-projects/SYNTHESIS.md` §Q5: "Forbidden in overlay: `UIBezierPath`, `NSBezierPath`, `CALayer.frame` math").

### The `Canvas` overlay shape

```swift
public struct DetectionLayer: View {
    public let detections: [Detection]
    public let videoRect: CGRect              // on-screen video rect (after letterbox)
    public let style: OverlayStyle

    public var body: some View {
        Canvas { context, size in
            for detection in detections {
                let rect = converter.viewRect(for: detection.normalizedBox, in: videoRect)
                context.stroke(Path(rect),
                               with: .color(style.color(for: detection.label)),
                               lineWidth: style.strokeWidth)
                // labels, keypoints, masks similar
            }
        }
        .drawingGroup()                       // Metal-backed offscreen render
        .allowsHitTesting(false)              // overlay doesn't intercept gestures
    }
}
```

Three modifiers do load-bearing work:

1. **`.drawingGroup()`** — renders the whole canvas to an offscreen Metal texture before compositing back. Cheap per-detection-add; perceptibly smoother at 60 Hz with dozens of boxes. SportVision uses this; `hackingwithswift.com` and Apple's WWDC21 graphics talk both recommend it for animated `Canvas` content. (Note: the guidance is "only use after measuring" — for Iris's case, we have the prior-art measurement from SportVision; it's already paid off.)
2. **`.allowsHitTesting(false)`** — gestures pass through to the player view underneath. Without this, a tap-to-pause on the player would hit the overlay first. Cheap, important.
3. **(implicit) `Canvas` immediate-mode drawing** — no per-detection view in the hierarchy; one Canvas redraws the whole frame's worth of boxes. That's what makes 30+ detection-rich frames feasible at 60 Hz.

### Animation cadence: `TimelineView`?

The candidate pattern is wrapping the `Canvas` in a `TimelineView(.animation)` for `60 fps`-or-host-rate redraws. Verdict: **don't, unless animation is needed.** Reasons:

- Detection results arrive at the detector's pace (10–30 Hz), not at the display refresh rate. There's no new data to draw between frames. A `TimelineView` ticking at 60 Hz would redraw the same Canvas with the same `[Detection]` 4–6× per detector frame — wasted work.
- The `Canvas` redraws naturally when its `detections` input changes (SwiftUI invalidates on `Equatable` mismatch). That happens at detector pace, exactly when it should.
- The exception: **playback scrub.** When the user is scrubbing, the player's `currentTime` is changing rapidly (60+ Hz from the slider drag), and the overlay must follow. There, a `TimelineView` would actually pay off — every host-rate tick, look up the detection result at the new `currentTime` and redraw. We adopt this *only inside the playback scrub flow*, gated by a `@State var isScrubbing: Bool`.

```swift
public struct DetectionLayer: View {
    let resultStore: ResultStore       // see §7 for shape
    let videoRect: CGRect
    let style: OverlayStyle
    @Binding var displayTime: CMTime   // live: clock-now; playback: AVPlayer.currentTime; scrub: slider value

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0/60)) { context in
            let detections = resultStore.lookup(at: displayTime)
            Canvas { ctx, size in
                draw(detections, in: ctx, size: size, videoRect: videoRect, style: style)
            }
            .drawingGroup()
            .allowsHitTesting(false)
        }
    }
}
```

The `TimelineView` here is used as the redraw clock; the actual *lookup* is what reads `displayTime`. For live capture, `displayTime` advances at host-clock pace and the lookup returns whatever the latest detection result is. For playback, `displayTime` follows `AVPlayer.currentTime` (via `addPeriodicTimeObserver`). For scrub, `displayTime` follows the slider's `Binding`. Same code, three contexts.

The `.animation` schedule will redraw as fast as the host (60 Hz / 120 Hz on ProMotion). That's the *upper bound*; if `resultStore.lookup` returns the same `[Detection]` as last tick (likely 4-6 ticks per detector result), SwiftUI's structural-equality check short-circuits the actual `Canvas` redraw thanks to `.drawingGroup()`'s offscreen cache plus `Canvas`'s view-identity stability. We pay the lookup but not the rendering. (Apple's guidance per the WWDC21 SwiftUI Canvas talk and `hackingwithswift.com` notes that heavy work inside `TimelineView` closures is the trap to avoid; `resultStore.lookup` is O(log n) on a tiny sorted array, well inside budget.)

### macOS parity

`Canvas`, `TimelineView`, `Path`, `Color`, `ZStack` — all part of SwiftUI's cross-platform surface. **Zero `#if os`** in `DetectionLayer.swift`. SportVision's `DetectionOverlayView.swift` is the working proof: 170 lines, runs identically on iOS and macOS. Iris's overlay inherits that property.

The only platform-aware concern is **where `videoRect` comes from** — `playerLayer.videoRect` is read on the player-host's `@MainActor`, vended out to SwiftUI via a binding. That happens inside the platform-bridged `PlayerHostiOS`/`PlayerHostMac` (§4); by the time `videoRect` reaches `DetectionLayer`, it's a `CGRect`, platform-free.

### Layer stack (final)

```
ZStack (SwiftUI):
   ┌───────────────────────────────────────────┐
   │  PlayerView    OR    CameraPreview        │   ← bottom: AVF-native pixels
   │  (NSView/UIView backed,                   │
   │   AVPlayerLayer / AVCaptureVideoPreviewLayer)│
   └───────────────────────────────────────────┘
   ┌───────────────────────────────────────────┐
   │  DetectionLayer                           │   ← top: SwiftUI Canvas
   │  (Canvas inside TimelineView,             │
   │   drawingGroup, allowsHitTesting=false)    │
   └───────────────────────────────────────────┘
```

That's the entire overlay architecture. The two layers don't know about each other; the SwiftUI `ZStack` is the only glue. App code composes them:

```swift
ZStack {
    PlayerView(source: session.previewSource)
    DetectionLayer(resultStore: results, videoRect: $videoRect,
                   style: .default, displayTime: $displayTime)
}
```

---

## 7. Frame synchronization

The hardest, most subtle problem in this block. Here it is in one diagram:

```
time →     t₀     t₁     t₂     t₃     t₄     t₅     t₆     t₇
           │      │      │      │      │      │      │      │
capture   [F₀]   [F₁]   [F₂]   [F₃]   [F₄]   [F₅]   [F₆]   [F₇]
           │             │             │             │
detector   ────analyze───┘             │             │
           │ result D₀                 │             │
           │ at time t₂ (Δ = 2 frames) │             │
           │ tagged with F₀.timestamp  │             │
           │             ────analyze───┘             │
           │             │ result D₂ at time t₄      │
           │             │ tagged with F₂.timestamp  │
           │             │             ────analyze───┘
           │             │             │ result D₄ at time t₆
           │             │             │
display   [F₀]   [F₁]   [F₂]   [F₃]   [F₄]   [F₅]   [F₆]   [F₇]
           │      │      │      │      │      │      │      │
overlay    ?      ?      D₀     D₀     D₂     D₂     D₄     D₄
                         ▲             ▲             ▲
                         │             │             │
                  most-recent     most-recent   most-recent
                  result ≤ t₂     result ≤ t₄   result ≤ t₆
```

**The fundamental fact:** detection results are *late* relative to the display by Δ (the detection latency). On screen at time `t`, the visible frame is `F_t`, but the most recent detection result is `D_{t-Δ}` (the detection that started Δ ago and just finished). If we naively draw `D_{t-Δ}` on top of `F_t`, the boxes lag behind the moving subject by Δ.

There is no free lunch: the detection result is physically about a frame that *was on screen Δ ago*. The displayed frame and the detected frame are not the same. The question is what to do about it.

### Live-capture strategy: "best-effort, timestamp-tagged"

The shipped strategy:

1. **Every `Frame` carries `timestamp: CMTime`** (sibling decision 9).
2. **Every detection result is tagged with its source `Frame.timestamp`.** The detector emits a `TimestampedDetections` value:
   ```swift
   public struct TimestampedDetections: Sendable, Hashable {
       public let timestamp: CMTime    // = source Frame.timestamp
       public let detections: [Detection]
   }
   ```
3. **The consumer stores results in a small ring buffer keyed by timestamp.** The "result store":
   ```swift
   @MainActor public final class ResultStore: Observable {
       private var buffer: [TimestampedDetections] = []   // sorted by timestamp, capacity ~30
       public func append(_ result: TimestampedDetections) {
           buffer.append(result)
           if buffer.count > 30 { buffer.removeFirst() }
       }
       public func lookup(at displayTime: CMTime) -> [Detection] {
           // O(log n): binary search for the most-recent timestamp ≤ displayTime
           // (PRVisionSpike pattern, ../prior-projects/PRVisionSpike.md §Notes)
           let idx = buffer.binarySearchInsertion(for: displayTime,
                                                   key: \.timestamp)
           if idx == 0 { return [] }
           return buffer[idx - 1].detections
       }
   }
   ```
4. **The overlay reads `displayTime` at draw time** and calls `lookup`. For live capture, `displayTime` is "now" — the host clock at the moment of the SwiftUI redraw. For playback, it's `AVPlayer.currentTime()`.
5. **The result drawn at host-time `t` is `lookup(t - some_correction)`.** For live capture, a correction of zero is fine — we have nothing later than the most-recent result anyway. The user sees the latest result on top of a frame Δ ahead of it. Boxes "trail" the subject; this is the expected behavior and matches what every prior-art project does in live mode.

The "best-effort" honesty: in live capture, **the boxes lag the subject by Δ**, and that's unavoidable without forward prediction (out of scope — domain choice for downstream apps, per the block context). The strategy above doesn't *fix* the lag; it ensures the lag is the minimum possible (the boxes are always the most-recent result we have, not some older cached value) and that the system never misalignes a result *with the wrong frame* (because we never associate a result with a frame that isn't its source).

A note on what this is *not*: it is NOT "wait for the detection to finish before drawing the frame." That would be **catastrophic** UX — a paused 60 fps preview every time the detector hiccuped. The display path is fully decoupled, by design (§5).

### Playback strategy: same model, different `displayTime` source

For playback, the same `TimestampedDetections` ring buffer works, with two differences:

1. **`displayTime` follows `AVPlayer.currentTime()`** — bound to the SwiftUI `@State` via `player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { time in displayTime = time }`. Periodic at host rate (60 Hz) so the overlay sees a fresh time per redraw.
2. **The detector typically runs *faster than real-time* in the pre-pass / scrub setup** (sibling §5, "consumer's detector pace is the constraint"; PRVisionSpike's asset-reader path runs as fast as the consumer reads). So `buffer` accumulates results in advance — by the time the player's `displayTime` reaches a frame, the detection for that frame is already in the buffer. Lookup is `at displayTime`, lookup returns the exact-or-just-before result. **The overlay is frame-accurate in playback**, with no lag.

If the asset is long, the ring buffer's `30`-element capacity isn't enough for a full-asset playback timeline; the M3 "playback observation cache" question (PRVisionSpike's sorted-array timeline, `../prior-projects/PRVisionSpike.md` §Notes; M0 verdict `../prior-projects/RECOMMENDATIONS.md` §"Interesting tangents") is the M3 follow-on. For M1+M2 (live capture), 30 is plenty. The shape of the lookup API doesn't change between the small ring buffer and the full timeline — only the eviction policy does.

### Edge cases

| Case | What the overlay sees |
| --- | --- |
| **Live capture, detector running normally** | `lookup(now)` → most-recent result. Boxes trail subject by Δ. |
| **Live capture, detector slower than ~1× frame rate** | Same — `lookup` returns the most-recent regardless of how old. If results are very stale (e.g. detector died), buffer fills with old timestamps and `lookup` keeps returning them. Solution: timestamp staleness check on the buffer (`if buffer.last.timestamp < now - 500ms { return [] }`) — surfaces "detector is broken" visually as "no boxes" instead of "wrong boxes." |
| **Playback, playing forward at 1×** | `lookup(player.currentTime)` → frame-accurate detection. No lag. |
| **Playback, scrubbing** | `displayTime` follows the slider's `Binding`. `lookup` returns whatever's in the buffer at that timestamp. If the user scrubs to a region the detector hasn't reached yet, lookup returns `[]` (the previous-result-≤-time is the previous frame's detections, not the current — see staleness check). M3 enhancement: prefetch detection ahead of the player by warming the asset-reader. |
| **Playback, pause** | `displayTime` stops changing; `lookup` returns the same result. Overlay is frozen on the correct frame's result. This is "free" — no special handling. |
| **Playback, seek (jump)** | `PlaybackSession.seek(to:)` rebuilds the reader (sibling decision 12); player jumps; old buffer is now invalid for past timestamps. Strategy: **clear the buffer on seek.** `PlaybackSession.seek` notifies `ResultStore.clear()` via the consumer's awareness. After clear, lookup returns `[]` until the detector catches up; the user sees an overlay-less frame for a few hundred ms. Acceptable; the alternative (showing stale results from before the seek) is worse. |
| **Display path falls behind (impossibly slow GPU)** | Doesn't happen in practice — the AVF preview/player paths are hardware-paced and don't fall behind in any case Iris will encounter. Out of scope. |

### What we deliberately do *not* do

- **Don't pin the overlay to the source frame.** This would mean *holding back the displayed frame* until its detection result arrives. That's what `AVSynchronizedLayer` would naturally do *for playback* — but it doesn't work for live capture, and it introduces a permanent Δ delay in the displayed video which is unacceptable.
- **Don't predict subject motion forward by Δ.** Per the block context: this is a domain choice (Kalman filter, optical flow, model-specific motion priors) and lives in downstream apps, not in Iris. Iris ships honest "best-effort, lagged" overlays; apps that want zero-lag can buffer their results and apply prediction themselves before handing the `[Detection]` to `DetectionLayer`.
- **Don't `Task.sleep(Δ)` the display to artificially match the detector.** Tempting; wrong. Real-time video does not get to insert deliberate latency.

---

## 8. Coordinate-space conversion

Locked: `NormalizedGeometryConverting` lives in **`IrisOverlay`**, per M0 verdict (`../prior-projects/RECOMMENDATIONS.md` §"Patterns to lift — Overlay & coordinate math") and the block's explicit scope. Two converter implementations:

```swift
public protocol NormalizedGeometryConverting {
    /// Convert a Vision-normalized (bottom-left-origin, 0…1) rect into the
    /// SwiftUI view's top-left-origin pixel space.
    func viewRect(forNormalized rect: CGRect, in videoRect: CGRect) -> CGRect
    func viewPoint(forNormalized point: CGPoint, in videoRect: CGRect) -> CGPoint
}

public struct PreviewLayerConverter: NormalizedGeometryConverting { /* delegates to
    AVCaptureVideoPreviewLayer.layerRectConverted(fromMetadataOutputRect:) at the seam */ }

public struct PlayerLayerConverter: NormalizedGeometryConverting { /* aspect-fit math
    against AVPlayerLayer.videoRect — Sportvision's ~25 lines */ }
```

The two backends differ in *how* they compute the rect — for capture, `AVCaptureVideoPreviewLayer` exposes `layerRectConverted(fromMetadataOutputRect:)` which AVF itself implements correctly (including front-camera mirroring); for playback, we do the math ourselves against `playerLayer.videoRect`. Same protocol contract, two implementations selected by the source of the frame.

**The converter takes a `videoRect: CGRect`** (the on-screen rect of the actual video content, accounting for letterbox/pillarbox via `videoGravity`). The `videoRect` comes from:

- **iOS capture:** `previewLayer.layerRectConverted(...)` handles it internally; callers pass the view bounds.
- **iOS+macOS playback:** `playerLayer.videoRect` directly. Read on `@MainActor` from the host view, passed up to SwiftUI as a `Binding<CGRect>`.

The Y-flip lives in **one place** — inside the converter's `viewRect(forNormalized:in:)`. Callers never write `1 - y - height` themselves (SportVision's centralized flip pattern, lifted verbatim).

Rotation and mirroring — already handled at the AVF connection level (§3, capture mirroring on the connection); the converter does not re-apply them. This composes cleanly because by the time a `Detection` reaches the overlay, its `normalizedBox` is already in the correct frame of reference (Vision was told the orientation, results come back oriented).

**macOS parity:** the converters are pure value types (`struct`), pure CGRect math, no platform types. Both implementations work identically on iOS and macOS. Zero `#if os` in `IrisOverlay`.

---

## 9. Public SwiftUI surface

Pulled together — the final shape M1+M3 will land:

### `IrisCapture` (iOS only)

```swift
public struct CameraPreview: UIViewRepresentable {
    public let source: PreviewSource
    public init(source: PreviewSource) { self.source = source }
    public func makeUIView(context: Context) -> PreviewView { … }
    public func updateUIView(_ uiView: PreviewView, context: Context) { /* no-op */ }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        ObjectIdentifier(lhs.source as AnyObject) == ObjectIdentifier(rhs.source as AnyObject)
    }
}

// PreviewSource + PreviewTarget already locked by sibling decision 15.
// PreviewView is internal — public API never sees the UIView.
```

### `IrisPlayback` (iOS + macOS)

```swift
public struct PlayerView: View {
    public let source: PlaybackPreviewSource
    public init(source: PlaybackPreviewSource) { self.source = source }
    public var body: some View { /* platform-bridged host inside */ }
}

public protocol PlaybackPreviewSource: Sendable {
    func connect(to target: PlaybackPreviewTarget)
}

@MainActor public protocol PlaybackPreviewTarget {
    func setPlayer(_ player: AVPlayer)
}

extension PlaybackSession {
    public nonisolated var previewSource: PlaybackPreviewSource { get }   // mirror of CaptureSession
    public var videoRect: AsyncStream<CGRect> { get }                     // tracked from the player layer
    public var currentTime: AsyncStream<CMTime> { get }                   // periodic time observer
}
```

`PlaybackSession`'s public API gains `previewSource` (mirror of capture's), `videoRect` (the on-screen video rect, tracked as it changes), and `currentTime` (periodic-observer-backed). The latter two are `AsyncStream`s so consumers can `for await` them into `@State` without owning the observation machinery.

### `IrisOverlay` (iOS + macOS)

```swift
public struct DetectionLayer: View {
    public let resultStore: ResultStore
    public let videoRect: CGRect
    public let displayTime: CMTime
    public let style: OverlayStyle
    public let converter: any NormalizedGeometryConverting
    public init(resultStore: ResultStore, videoRect: CGRect, displayTime: CMTime,
                style: OverlayStyle = .default,
                converter: any NormalizedGeometryConverting = PlayerLayerConverter())
    public var body: some View { /* TimelineView + Canvas, §6 */ }
}

@MainActor @Observable public final class ResultStore {
    public init(capacity: Int = 30)
    public func append(_ result: TimestampedDetections)
    public func clear()
    public func lookup(at displayTime: CMTime) -> [Detection]
}

public struct TimestampedDetections: Sendable, Hashable {
    public let timestamp: CMTime
    public let detections: [Detection]
    public init(timestamp: CMTime, detections: [Detection])
}

public protocol NormalizedGeometryConverting {
    func viewRect(forNormalized rect: CGRect, in videoRect: CGRect) -> CGRect
    func viewPoint(forNormalized point: CGPoint, in videoRect: CGRect) -> CGPoint
}
public struct PreviewLayerConverter: NormalizedGeometryConverting { … }
public struct PlayerLayerConverter: NormalizedGeometryConverting { … }
```

### Composition (in an app)

```swift
// Live capture
@MainActor struct CaptureView: View {
    let session: CaptureSession           // sibling's actor
    @State var displayTime: CMTime = .zero
    @State var resultStore = ResultStore()

    var body: some View {
        ZStack {
            CameraPreview(source: session.previewSource)
            DetectionLayer(resultStore: resultStore,
                           videoRect: previewVideoRect,   // tracked elsewhere
                           displayTime: displayTime,
                           converter: PreviewLayerConverter())
        }
        .task { try? await session.start() }
        .task {
            for await frame in session.frames {
                let result = try? await detector.detect(frame)
                resultStore.append(TimestampedDetections(
                    timestamp: frame.timestamp,
                    detections: result ?? []))
            }
        }
    }
}

// Playback
@MainActor struct PlaybackView: View {
    let session: PlaybackSession
    @State var displayTime: CMTime = .zero
    @State var videoRect: CGRect = .zero
    @State var resultStore = ResultStore(capacity: 600)   // larger for asset-length

    var body: some View {
        ZStack {
            PlayerView(source: session.previewSource)
                .onAppear { /* observe session.videoRect / session.currentTime */ }
            DetectionLayer(resultStore: resultStore,
                           videoRect: videoRect,
                           displayTime: displayTime,
                           converter: PlayerLayerConverter())
        }
        .task { try? await session.start() }
        .task { for await rect in session.videoRect { videoRect = rect } }
        .task { for await time in session.currentTime { displayTime = time } }
        .task {
            for await frame in session.frames {
                let result = try? await detector.detect(frame)
                resultStore.append(TimestampedDetections(
                    timestamp: frame.timestamp,
                    detections: result ?? []))
            }
        }
    }
}
```

Notice: **`AVCaptureSession` and `AVPlayer` never appear** in the consumer's code. The public surface is `PreviewSource`, `PlaybackPreviewSource`, `CameraPreview`, `PlayerView`, `DetectionLayer`, `ResultStore`, `TimestampedDetections`, `NormalizedGeometryConverting`. The AVF type system stays behind the seam, as `CLAUDE.md` requires.

---

## 10. Open items remaining

These surfaced during synthesis but couldn't be fully locked. None block M1.

1. **`videoRect` observation mechanism.** Reading `AVPlayerLayer.videoRect` reactively (so the overlay updates when the user resizes the window or rotates the device) requires KVO on the layer. The clean SwiftUI path is `playerLayer.observe(\.videoRect, options: [.initial, .new]) { layer, _ in continuation.yield(layer.videoRect) }` inside an `AsyncStream`. Works, but the KVO observation is a `nonisolated` closure that has to hop to `@MainActor` to read the layer property. M3 implementation detail; not load-bearing on the protocol shape.

2. **Ring-buffer capacity for live capture.** `30` is a heuristic — covers ~1 second at 30 fps, ~500 ms at 60 fps. Long enough for the lookup to find a result; short enough that lag staleness is bounded. M2 will pick a number; the API doesn't depend on it.

3. **Detector latency telemetry.** It would help apps tune their UX if `ResultStore` exposed observed Δ (`displayTime - lookup_result_timestamp`). Trivial to add; deferred to M2 / M4 (where `IrisTuning` might display it).

4. **`PreviewSource.connect(to:)` semantics for re-connection.** What happens if a `CameraPreview` view is recreated in SwiftUI (despite the `==` trick)? `connect` is called again, the layer's session is re-assigned. Should be idempotent — and AVF tolerates re-assigning the same session — but spec a test. M1 detail.

5. **macOS scrub UI.** The block context flagged this; it lives in `IrisTuning` rather than `IrisOverlay` / `IrisPlayback`. The overlay's `displayTime` binding is the seam; the scrub control reads/writes that binding. Out of scope for this synthesis.

6. **Multi-subscriber broadcast.** Sibling open item 2. Still deferred to M3+ when `IrisDataset` joins. The display-pipeline architecture is compatible with both fan-out strategies (single-consumer + app-level fan-out, or `[UUID: Continuation]` broadcast), since display doesn't tap `Source` regardless.

---

## Sources cited

### Prior art (in-house)
- [`../runtime-pipeline-architecture/SYNTHESIS.md`](../runtime-pipeline-architecture/SYNTHESIS.md) — sibling's data-plane locks.
- [`../runtime-pipeline-architecture/RECOMMENDATIONS.md`](../runtime-pipeline-architecture/RECOMMENDATIONS.md) — sibling's 20 decisions + anti-pattern list (esp. "no `AVPlayerItemVideoOutput`").
- [`../prior-projects/SYNTHESIS.md`](../prior-projects/SYNTHESIS.md) — M0 verdict on Q5 (macOS overlay parity, SwiftUI `Canvas` solution).
- [`../prior-projects/RECOMMENDATIONS.md`](../prior-projects/RECOMMENDATIONS.md) — overlay & coordinate-math patterns, `NormalizedGeometryConverting`.
- [`../prior-projects/sportvision.md`](../prior-projects/sportvision.md) — `DetectionOverlayView.swift` proof-of-concept for cross-platform `Canvas` overlay.
- [`../prior-projects/PRVisionSpike.md`](../prior-projects/PRVisionSpike.md) — `AVPlayer` + `AVAssetReader` coexistence, sorted-timeline binary-search lookup pattern.
- [`../swift-ecosystem/apple-avcam.md`](../swift-ecosystem/apple-avcam.md) — `PreviewSource` / `PreviewTarget` indirection.
- [`../swift-ecosystem/mijick-camera.md`](../swift-ecosystem/mijick-camera.md) — `UIViewRepresentable` `==` trick.
- [`../swift-ecosystem/nextlevel.md`](../swift-ecosystem/nextlevel.md) — Swift 6 + AVFoundation footgun reference (informs why we keep AVF behind the seam).
- [`../swift-ecosystem/kadr.md`](../swift-ecosystem/kadr.md) — cross-platform discipline; pure-Swift value types over CALayer math.

### Apple docs / community references (targeted lookups, 2026-05-20)
- [AVCaptureVideoPreviewLayer reference](https://developer.apple.com/documentation/avfoundation/avcapturevideopreviewlayer) — session attach point, `layerClass` override, `layerRectConverted(...)` helpers.
- [AVPlayerLayer reference](https://developer.apple.com/documentation/avfoundation/avplayerlayer) — `player` property, `videoGravity`, `videoRect`.
- [`videoRect`](https://developer.apple.com/documentation/avfoundation/avplayerlayer/1385745-videorect) — letterbox/pillarbox aware on-screen rect.
- [AVSampleBufferDisplayLayer reference](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer) — confirmed as lower-level option for custom pipelines (we don't need it).
- [AVSynchronizedLayer reference](https://developer.apple.com/documentation/avfoundation/avsynchronizedlayer) — confirmed `AVPlayerItem`-only, no capture-session variant.
- [AVPlayerItemVideoOutput reference](https://developer.apple.com/documentation/avfoundation/avplayeritemvideooutput) — confirmed as the display-link-coupled extraction path the sibling explicitly banned.
- [Apple AVCam sample (iOS 26)](https://developer.apple.com/documentation/avfoundation/avcam-building-a-camera-app) — canonical `PreviewSource`/`PreviewTarget` source.
- [WWDC21: What's new in AVKit](https://developer.apple.com/videos/play/wwdc2021/10290/) — context for `AVSampleBufferDisplayLayer` PiP usage (why it's preferred only when you have a custom pipeline).
- [Hacking with Swift: drawingGroup() performance](https://www.hackingwithswift.com/books/ios-swiftui/enabling-high-performance-metal-rendering-with-drawinggroup) — Metal-backed `Canvas` rendering guidance.
- [SwiftUI Lab: Canvas + TimelineView](https://swiftui-lab.com/swiftui-animations-part5/) — `TimelineView(.animation)` for host-rate redraw.
- [Cindori: Custom video player in SwiftUI with AVKit](https://cindori.com/developer/building-video-player-swiftui-avkit) — `AVPlayerLayer` on NSView via NSViewRepresentable pattern.
- [Benoit Pasquier: AVPlayer in SwiftUI](https://benoitpasquier.com/playing-video-avplayer-swiftui/) — `layerClass` override for AVPlayerLayer (iOS).
- [Sérgio Estêvão: Video in SwiftUI on macOS](https://sergioestevao.com/2020/02/22/video-in-swiftui-macos/) — `AVPlayerView` (AVKit) vs `AVPlayerLayer` on NSView — we picked the layer for bare display surface.
- [Yevhenii Peteliev: Understanding AVSynchronizedLayer](https://medium.com/@peteliev/avfoundation-understanding-avsynchronizedlayer-e922d2676b9) — `AVPlayerItem`-only confirmation, beginTime gotcha.
- [Apple Developer Forums: Accessing decoded frames (concurrent)](https://developer.apple.com/forums/thread/650435) — `AVPlayerItemVideoOutput`+`CADisplayLink` is the canonical extraction path *if you were going to do it* (we aren't).
