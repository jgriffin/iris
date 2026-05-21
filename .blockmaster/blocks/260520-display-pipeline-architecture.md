# display-pipeline-architecture — Display pipeline: preview, player, overlay, frame sync

parent: [m0-explorations](.blockmaster/blocks/260520-m0-explorations.md)
created: 2026-05-20 17:00
modified: 2026-05-20 17:00
context: .blockmaster/blocks/260520-display-pipeline-architecture.md
kind: exploration
goal: Lock the architecture for displaying captured/playing frames to the user, layering overlays on top, and keeping detector results frame-synchronized with what's on screen — without violating the `.bufferingNewest(1)` single-listener contract from the sibling block.

### Context

Sibling to [runtime-pipeline-architecture](.blockmaster/blocks/260520-runtime-pipeline-architecture.md). That block locked the **data plane**: how frames flow from camera/asset → `AsyncStream<Frame>` → consumer, with `.bufferingNewest(1)` back-pressure and an `actor`-isolated `CaptureSession`. It deliberately deferred everything about *displaying* those frames — and the user noticed: the playback synthesis describes `AVAssetReader` (a frame-extraction path) but never says how the user actually *sees* the video while it plays. Same problem on the capture side — `AVCaptureSession` produces sample buffers, but the preview surface is a separate concern.

This block resolves that. The core architectural questions:

1. **Where do display surfaces live?** `AVCaptureVideoPreviewLayer` for camera, `AVPlayer` + `AVPlayerLayer` (or `AVSampleBufferDisplayLayer`) for playback — these are CALayer-level surfaces, not SwiftUI views. How do they reach the public SwiftUI API (`CameraPreview`, presumably a `PlayerView`) without leaking UIKit/AppKit?
2. **The fan-out problem.** A `Source` vends an `AsyncStream<Frame>` with `.bufferingNewest(1)` and a single consumer. But we need *two* consumers: the detector (slow, drops to newest) and the display (fast, drops to newest at video frame rate). Does display tap the stream, or does it bypass the `Source` entirely and read at a lower layer (preview layer / player time observer)?
3. **Overlay layering.** SwiftUI `Canvas` on top of the preview/player view (per `sportvision` prior art), or composed into the same CALayer tree, or via `AVSynchronizedLayer`? Pros, cons, parity story for macOS.
4. **Frame synchronization.** Capture happens at *t*. Detection completes at *t + Δ* (tens to hundreds of ms). The frame visible on screen at *t + Δ* is *t + Δ* (live), not *t* (when the detection started). How do we draw boxes on the correct on-screen frame so the overlay doesn't lag visibly? Same problem on playback during scrub.

### Scope

**In:**

- **Capture preview** — `AVCaptureVideoPreviewLayer` ownership, wrapping in `UIViewRepresentable`, mirroring/rotation, the relationship between the preview layer and the `AVCaptureSession` (it's attached to the same session; not a separate frame path).
- **Playback display** — `AVPlayer` + `AVPlayerLayer` vs `AVSampleBufferDisplayLayer` vs rendering frames manually. How `AVPlayer` and `AVAssetReader` coexist (or whether one replaces the other in the design).
- **Public SwiftUI surface** — `CameraPreview`, `PlayerView` (or whatever the playback counterpart is called) — how the public API stays SwiftUI-shaped while wrapping CALayer/UIView internals.
- **Source fan-out** — how the *same* underlying source feeds (a) the on-screen display and (b) the detector pipeline. Options: tap the `AsyncStream` (violates `.bufferingNewest(1)` for the second consumer); broadcast/multiplex the stream (deferred item from sibling block); bypass `Source` for display and use the lower-level AVF surfaces directly (preview layer / player); some hybrid.
- **Overlay architecture** — SwiftUI `Canvas` overlay (sportvision pattern), `AVSynchronizedLayer`, custom `CALayer` composition. Pick one; macOS parity story.
- **Frame synchronization** — strategies for keeping detector overlays aligned with what the user sees. Per-frame timestamp carried through detection back to overlay; overlay reads the player/preview "current time" to decide which result to draw; latency budget; what happens during scrub or pause.
- **Coordinate-space conversion** — surface-vs-image rect math (letterbox/pillarbox), Y-flip, rotation. Already largely resolved by prior-art `NormalizedGeometryConverting` protocol; confirm it lives here and stays platform-agnostic.

**Out:**

- Detector implementation (covered or deferred by sibling)
- Sidecar / dataset format (Q3 — separate block)
- Tuning UI (`IrisTuning`)
- Foundation Models / `Captioner` (Q6)
- Package layout (separate open question)

### Open questions this resolves

- **Display surface choice for playback** — `AVPlayer`-driven (`AVPlayerLayer`) vs frame-pump-driven (`AVSampleBufferDisplayLayer`).
- **Fan-out strategy** — does the display layer tap `Source`, or does it use AVF's native preview/player path while the detector keeps the single `Source` listener?
- **Overlay layer choice** — SwiftUI `Canvas` over `UIViewRepresentable`-wrapped preview, vs `AVSynchronizedLayer`, vs custom `CALayer` composition.
- **Frame-sync model** — timestamp-tagged detection result + overlay reads "current display time" to pick the closest result, vs other strategies.
- **`IrisOverlay` shape** — confirm it's a separate module (per `BRIEF.md`) and how it consumes detector output without re-driving the source.

### Inputs

- `BRIEF.md` — architecture, principles, six-module layout
- `explorations/runtime-pipeline-architecture/SYNTHESIS.md` + `RECOMMENDATIONS.md` — sibling's locked data-plane design
- `explorations/prior-projects/sportvision.md` — strongest signal on SwiftUI `Canvas` overlay + macOS parity
- `explorations/prior-projects/PRVisionSpike.md` — Vision→overlay seam
- `explorations/prior-projects/SYNTHESIS.md` §macOS overlay parity verdict (Q5)
- `explorations/swift-ecosystem/apple-avcam.md`, `mijick-camera.md`, `nextlevel.md` — preview-layer ownership patterns
- Apple docs: `AVCaptureVideoPreviewLayer`, `AVPlayerLayer`, `AVSampleBufferDisplayLayer`, `AVSynchronizedLayer`, `AVPlayerItemVideoOutput`, time observers
- WWDC sessions on AV preview, video composition, synchronized overlays (search current sessions)

### Approach

Same methodology as the sibling: synthesis-heavy with targeted Apple-docs lookups, single focused researcher, producing two deliverables. Decisions must be locked, not surveyed.

### Output

Under `explorations/display-pipeline-architecture/`:

- `SYNTHESIS.md` — architectural narrative + layer-stack diagrams + frame-sync timeline diagrams + code-shape sketches for the public SwiftUI surface
- `RECOMMENDATIONS.md` — locked decisions for M1+ in the same shape as the sibling's

### Progress

- 2026-05-20 17:00 — created and opened. Sibling to `runtime-pipeline-architecture` (now ✅). Scope: preview/player display, overlay layering, source fan-out, frame sync. Researcher dispatch pending.
- 2026-05-20 — researcher returned `SYNTHESIS.md` (848 lines) + `RECOMMENDATIONS.md` (474 lines, 27 locked decisions). All four headline questions resolved; zero tensions with sibling block. User signed off.

### Outcome

Deliverables under [`explorations/display-pipeline-architecture/`](../../explorations/display-pipeline-architecture/):

- [`SYNTHESIS.md`](../../explorations/display-pipeline-architecture/SYNTHESIS.md) — 848-line narrative. Two-parallel-paths diagram (display via AVF preview/player layer; analysis via `Source` → detector → overlay). Frame-sync timing diagram. Coordinate-space conversion. Public SwiftUI surface signatures. Open items.
- [`RECOMMENDATIONS.md`](../../explorations/display-pipeline-architecture/RECOMMENDATIONS.md) — 474 lines, 27 locked decisions + type sketches (`CameraPreview`, `PlayerView` + platform hosts, `DetectionLayer`, `ResultStore`, `TimestampedDetections`, `NormalizedGeometryConverting`), M1/M2/M3 scope additions, anti-patterns, deferred items.

**Locked verdicts:**

- **Playback display surface** — `AVPlayer` + bare `AVPlayerLayer` (layer-backed `UIView` / `NSView`). Rejected `AVSampleBufferDisplayLayer` (re-implements `AVPlayer` for no gain), AVKit `VideoPlayer` / `AVPlayerView` (ships transport controls, no `videoRect` hook), manual Metal (unnecessary doubling of the asset-reader path).
- **Fan-out** — display does **not** consume `Source.frames`. The two consumers tap *different AVF surfaces of the same root* (preview-layer + data-output on a capture session; player-layer + asset-reader on an asset). `Source` stays single-consumer; sibling's `.bufferingNewest(1)` contract is preserved trivially because the "second consumer" never materializes.
- **Overlay layer** — pure SwiftUI `Canvas` in a `ZStack` over the display view, wrapped in `TimelineView(.animation(minimumInterval: 1.0/60))`, with `.drawingGroup()` and `.allowsHitTesting(false)`. Rejected `AVSynchronizedLayer` (**capture-incompatible — `AVPlayerItem`-only**), custom `CALayer`, `UIBezierPath` / `NSBezierPath`. macOS parity automatic.
- **Frame-sync model** — results tagged with source `Frame.timestamp`, stored in a sorted ring buffer (`ResultStore`). Overlay reads `displayTime` at draw time (host clock live; `AVPlayer.currentTime` playback; slider binding scrub) and does O(log n) binary-search lookup of "most-recent result ≤ displayTime." Staleness threshold returns `[]` if newest result is older than 500 ms (live) / 2 s (playback). `seek` clears the store before reader rebuild. Iris ships **best-effort lagged** overlays in live capture; **frame-accurate** in playback.

**Three findings worth surfacing to BRIEF.md refresh:**

1. `AVSynchronizedLayer` is `AVPlayerItem`-only — no capture-session variant exists. This single fact rules out a whole class of designs and forces SwiftUI `Canvas` as the unifying overlay choice.
2. The fan-out "problem" dissolves once you frame AVF as providing two parallel hardware paths off the same root. The "second consumer" of `Source` everyone worries about never materializes — display is a sibling path, not a downstream consumer.
3. `videoRect` is load-bearing — both `AVCaptureVideoPreviewLayer.layerRectConverted(...)` (capture, AVF handles math) and `AVPlayerLayer.videoRect` (playback, expose directly) give the post-letterbox on-screen rect. Threading it through to the overlay as a `CGRect` parameter keeps `DetectionLayer` platform-pure.

**Composes cleanly with sibling** [runtime-pipeline-architecture](.blockmaster/blocks/260520-runtime-pipeline-architecture.md):

- `Source` stays `.bufferingNewest(1)` single-consumer (sibling #2, #14) — display isn't a consumer.
- `previewSource` (sibling #15) mirrored to `playbackPreviewSource`.
- `AVPlayerItemVideoOutput` ban (sibling anti-pattern) reaffirmed.
- `@preconcurrency import` gating (sibling #18) extended to the new host-view files.
- No Combine, no per-frame `Task` (sibling #19, #20) — KVO on `videoRect` wrapped in `AsyncStream`.
- `Frame.timestamp` first-class (sibling #9) is what makes `TimestampedDetections` lookup possible.

**Deferred:** ring-buffer capacity tuning (heuristic 30; M3 may need hundreds for long-asset playback — API unchanged, eviction policy only); forward motion prediction for zero-lag live overlays (downstream-app domain choice); macOS scrub UI (lives in `IrisTuning`, not here).

**Followed by:** sibling block [project-shape-and-tooling](.blockmaster/blocks/260520-project-shape-and-tooling.md) — last M0 child covering repo/package layout, iOS+macOS test apps, and build tooling.
