# runtime-pipeline-architecture — Frame pipeline architecture: Capture · Playback → Frame

parent: [m0-explorations](.blockmaster/blocks/260520-m0-explorations.md)
created: 2026-05-20 16:00
modified: 2026-05-20 16:00
context: .blockmaster/blocks/260520-runtime-pipeline-architecture.md
kind: exploration
goal: Lock the technical architecture for getting frame data out of `AVCaptureSession` (iOS) and `AVAssetReader` (iOS+macOS) performantly, behind a source-agnostic `Frame` boundary, with a defined Swift 6 isolation model.

### Context

Synthesis-focused exploration following M0's prior-art + ecosystem surveys. The breadth pass is done; this block converts the resulting recommendations into a concrete runtime-pipeline design before M1 capture planning opens.

The user's framing: *"How we set up the AV capture stuff and the video playback bits so that we can get frames out, frame data out in a performant way."* Detection is treated as a downstream consumer at the boundary — what does it need from a `Frame` to consume it efficiently — **not** as detector internals, threading, or hot-swap.

### Scope

**In:**

- `AVCaptureSession` setup: device selection, format, pixel format choice, delegate vs `AsyncStream` bridging
- `AVAssetReader`-backed playback: buffer cadence, seek/scrub, frame-step semantics
- `Frame` boundary type: pixel buffer ownership/lifetime, metadata (timestamp, orientation, source), whether it's a struct of references
- Performance: `CVPixelBufferPool`, IOSurface-backed zero-copy, back-pressure, drop policy when consumers fall behind, allocator pressure
- Capture-side isolation: `@CaptureActor` shape; where the camera delegate callback hops to; how `AsyncStream` continuation interacts with strict concurrency
- Downstream boundary: what `Frame` must carry for Vision/Core ML to consume it efficiently (pixel format compatibility, orientation, timestamp)

**Out:**

- Detector internals, threading, hot-swap (Q4)
- `IrisOverlay` rendering, coordinate-space math
- `IrisTuning`, `IrisDataset` (just a downstream listener — not a design driver)
- Sidecar format choices (Q3)
- Foundation Models / `Captioner` (Q6)

### Open questions this resolves

- **Q1** — `AsyncStream<Frame>` vs an `AsyncSequence` protocol (the frame transport surface)
- **Q2** — Explicit `@CaptureActor` in the public API (capture-side isolation)
- Touches **Q5** for Playback only (the first macOS target); does not resolve overlay parity

### Inputs

- `BRIEF.md` — architecture, invariants, open questions
- `explorations/prior-projects/SYNTHESIS.md` + `RECOMMENDATIONS.md` — verdicts from in-house prior art
- `explorations/swift-ecosystem/RECOMMENDATIONS.md` — verdicts from external packages
- `explorations/RECOMMENDATIONS-PRIOR-ART.md` — cross-cutting rollup
- Targeted lookups: Apple `AVFoundation`, `AVCaptureSession` modern async APIs, `AVAssetReader` pacing, `CVPixelBuffer` / `CVPixelBufferPool` / `IOSurface` semantics, Swift 6 strict-concurrency patterns for delegate callbacks

### Approach

Synthesis-heavy, not breadth-heavy — the M0 surveys already did the breadth pass. Methodology:

1. **Single focused researcher** reads inputs + does targeted Apple-docs / Swift-evolution lookups for capture/playback/isolation specifics.
2. Researcher writes:
   - `explorations/runtime-pipeline-architecture/SYNTHESIS.md` — architectural narrative, ASCII data-flow diagrams, type sketches, isolation map
   - `explorations/runtime-pipeline-architecture/RECOMMENDATIONS.md` — concrete decisions to lock before M1 starts (per the per-exploration RECOMMENDATIONS convention)
3. Review + propose decisions back to user → close.

Alternative if the single-researcher pass feels thin: two-arc fork into **data plane** (frame transport, performance, pool/IOSurface) and **control plane** (isolation, lifecycle, source-agnostic boundary). Available if needed.

### Output

Under `explorations/runtime-pipeline-architecture/`:

- `SYNTHESIS.md` — architectural narrative + diagrams + isolation map
- `RECOMMENDATIONS.md` — locked decisions for M1

### Progress

- 2026-05-20 16:00 — created and opened; scope tightened to source-side (Capture + Playback → Frame); detector internals out, dataset out; researcher dispatched
- 2026-05-20 — researcher returned `SYNTHESIS.md` + `RECOMMENDATIONS.md`. Q1 locked (concrete `AsyncStream<Frame>` from a `Source` protocol, `.bufferingNewest(1)`, non-throwing). Q2 locked (actor instance with custom `DispatchSerialQueue` executor — no `@globalActor`). 20 locked decisions + 11 M1 scope additions + 12 anti-patterns + 6 deferred items.
- 2026-05-20 — user signed off. Block closed. Sibling `display-pipeline-architecture` opened to cover the rendering/preview/overlay/sync layer that this block's scope deliberately deferred.

### Outcome

Deliverables under [`explorations/runtime-pipeline-architecture/`](../../explorations/runtime-pipeline-architecture/):

- [`SYNTHESIS.md`](../../explorations/runtime-pipeline-architecture/SYNTHESIS.md) — 713-line architectural narrative. End-to-end ASCII data-flow diagram (camera/asset → delegate queue → `@CaptureActor` instance → `AsyncStream` → consumer). Code-shape sketches for `AVCaptureSession` setup, the delegate → `AsyncStream` bridge, `AVAssetReader` playback (forward-only + seek-via-recreate), the `Frame` type, the `Source` protocol. Isolation map + performance section + 6 explicitly-open items.
- [`RECOMMENDATIONS.md`](../../explorations/runtime-pipeline-architecture/RECOMMENDATIONS.md) — 379 lines, 20 locked decisions with rationale + "what M1 must do." Final Swift signatures for `Frame`, `Source`, `CaptureSession`, `PlaybackSession`, `SampleBufferRouter`. 11 M1 scope additions, 12 anti-patterns, 6 deferred items.

**Locked verdicts:**

- **Q1 — frame transport.** `Source` protocol vends a *concrete* `AsyncStream<Frame>` (not `some AsyncSequence`), with `bufferingPolicy: .bufferingNewest(1)` baked into the contract. **Non-throwing** — errors live on a separate `state` channel. Following `PrivateFoundationModels`' precedent over existential/opaque dance.
- **Q2 — capture-side isolation.** **No `@globalActor`.** `CaptureSession` is an `actor` *instance* with a custom `DispatchSerialQueue` serial executor (AVCam's `CaptureService` pattern). The delegate queue *is* the actor's executor — zero per-frame actor hops, no per-frame `Task` spawn inside the framework. Refinement of M0's earlier "build `@CaptureActor`" language: same compile-time guarantees, no global-actor spill across the module.
- **Touched Q5** — `IrisPlayback` shape on macOS matches iOS exactly (no camera divergence here).

**Surprises worth surfacing to BRIEF.md refresh:**

1. TN2445 still recommends `alwaysDiscardsLateVideoFrames = true` unconditionally for analysis pipelines — non-configurable, no Iris use case wants `false`.
2. `startRunning()`, `beginConfiguration()`, `commitConfiguration()` must all execute on the *same* serial queue as the delegate. AVCam pattern gives this for free; easy to miss if executor and configuration sites separate.
3. `kCVPixelBufferIOSurfacePropertiesKey: [:]` must be set explicitly on playback's `AVAssetReaderTrackOutput` for zero-copy. Capture inherits from AVF's pool; playback does not.

**Six items explicitly deferred** (now inherited by future blocks): multi-subscriber stream broadcast (defer to M3 when second listener arrives), `PreviewSource` package-boundary ownership (depends on package-layout decision), rotation snapshot-vs-per-frame cadence (profile in M2), `Source` consumer-cancel semantics, `Frame.dimensions` cache (profile in M2), audio capture (out until M5+).

**Followed by:** sibling block [display-pipeline-architecture](.blockmaster/blocks/260520-display-pipeline-architecture.md) — covers preview/player rendering, overlay layering, fan-out from a single `Source` to display + detection without violating `.bufferingNewest(1)`, and frame-sync between detector results and what's on screen.
