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

### Pick-up-here

Block opened. Researcher dispatch incoming. Awaiting `SYNTHESIS.md` + `RECOMMENDATIONS.md` under `explorations/display-pipeline-architecture/`. Headline decisions to extract: (a) display surface choice for playback, (b) fan-out strategy that doesn't break sibling's `.bufferingNewest(1)` contract, (c) overlay layer + macOS parity, (d) frame-sync model. After return: review with user, write Outcome, close. After close: M0 has both architecture sibling blocks closed and is ready to close, optionally after BRIEF.md refresh.

### Progress

- 2026-05-20 17:00 — created and opened. Sibling to `runtime-pipeline-architecture` (now ✅). Scope: preview/player display, overlay layering, source fan-out, frame sync. Researcher dispatch pending.
