---
blocks_version: 1
---

# Active

## 🟡 [m0-explorations](.blockmaster/blocks/260520-m0-explorations.md) — Upfront explorations before code starts

milestone · branch main · created 2026-05-20 · 1 active child · 4 recently closed
Pick-up-here: Both architecture sibling blocks closed (`runtime-pipeline-architecture` ✅, `display-pipeline-architecture` ✅). BRIEF.md now carries an "Architecture references" section linking both. Fifth child [project-shape-and-tooling](.blockmaster/blocks/260520-project-shape-and-tooling.md) 🟡 now open — covers Swift package layout (single vs split), iOS+macOS test apps, build tooling chain, fixture story. **No researcher dispatched yet** — per user direction, awaiting input on methodology (researcher vs interactive walk-through). After it closes: M0 ready to close, optionally after BRIEF.md refresh pass folding in all accumulated verdicts.

### ✅ [survey-dev-folder](.blockmaster/blocks/260520-survey-dev-folder.md) — Survey ~/dev/ for camera / capture / detection prior art

research · closed 2026-05-20
Outcome: Shortlist of 5 deep-read candidates (PR/ios-videoCapture, PR/PRVisionSpike, ml/yolo-ios-app, ml/sportvision, pocketRadar/BuildingAFeatureRichApp…). Full sweep covered 24 top-level folders + 5 recursed category folders; 9 had signal, 4 low-value entries dropped.

### ✅ [review-prior-projects](.blockmaster/blocks/260520-review-prior-projects.md) — Deep-read shortlisted prior projects

research · closed 2026-05-20
Outcome: 5 per-project notes + `SYNTHESIS.md` (verdicts on `BRIEF.md`'s 6 M1 open questions) + `RECOMMENDATIONS.md` (in-house-scoped patterns with code pointers) under `explorations/prior-projects/`. Strong verdicts: `@CaptureActor` in `IrisCapture` public API; SwiftUI `Canvas` overlay with one centralized Y-flip gives macOS parity for free; `Detector` is a `Sendable` protocol with mixed `struct`/`actor` conformers, hot-swap by replacing the instance, `VNCoreMLModel` cached outside detectors. 7 additions proposed for M1 scope (most notably `Detector.warmup()`, letterbox/pillarbox alignment, `.bufferingNewest(1)` back-pressure, `Frame.timestamp` first-class). Still open: COCO vs YOLO sidecar; Foundation Models scope; `Source` protocol unification; cancellation policy.

### ✅ [survey-swift-ecosystem](.blockmaster/blocks/260520-survey-swift-ecosystem.md) — Survey the wider Swift package ecosystem

research · closed 2026-05-20
Outcome: Both children closed. SHORTLIST + 5 external-package deep reads under `explorations/swift-ecosystem/`; per-arc recommendations at `explorations/swift-ecosystem/RECOMMENDATIONS.md`; cross-cutting rollup at `explorations/RECOMMENDATIONS-PRIOR-ART.md`. Verdicts: AVCam **Borrow**, NextLevel **Study-then-diverge**, MijickCamera **Study-then-diverge**, Kadr **Borrow structurally**, PrivateFoundationModels **Study-then-diverge**. Resolutions: Q6 (two protocols `Detector` + `Captioner`), Source-protocol unification (yes, do it), `DetectorCache` (injectable instance), cancellation (`AsyncStream` + consumer-owned task). New open question raised: package layout (single-package vs core + adapter-repos). 15+ new patterns to lift; ~12 new M1-scope additions.

### ✅ [runtime-pipeline-architecture](.blockmaster/blocks/260520-runtime-pipeline-architecture.md) — Frame pipeline architecture: Capture · Playback → Frame

exploration · closed 2026-05-20
Outcome: `SYNTHESIS.md` (713 lines) + `RECOMMENDATIONS.md` (379 lines, 20 locked decisions) under `explorations/runtime-pipeline-architecture/`. **Q1 locked:** `Source` protocol → concrete `AsyncStream<Frame>`, `.bufferingNewest(1)`, non-throwing (errors on a separate `state` channel). **Q2 locked:** no `@globalActor` — `CaptureSession` is an `actor` instance with a custom `DispatchSerialQueue` serial executor (AVCam `CaptureService` pattern), delegate queue *is* the executor, zero per-frame hops. Surprises for BRIEF.md refresh: `alwaysDiscardsLateVideoFrames = true` non-configurable per TN2445; config calls must share executor queue; `kCVPixelBufferIOSurfacePropertiesKey: [:]` required on playback `AVAssetReaderTrackOutput` for zero-copy. 6 items deferred (multi-subscriber broadcast, `PreviewSource` ownership, rotation cadence, cancel semantics, `Frame.dimensions` cache, audio).

### ✅ [display-pipeline-architecture](.blockmaster/blocks/260520-display-pipeline-architecture.md) — Display pipeline: preview, player, overlay, frame sync

exploration · closed 2026-05-20
Outcome: `SYNTHESIS.md` (848 lines) + `RECOMMENDATIONS.md` (474 lines, **27 locked decisions**) under `explorations/display-pipeline-architecture/`. **Playback display:** `AVPlayer` + bare `AVPlayerLayer` (layer-backed `UIView`/`NSView`). **Fan-out:** display does NOT consume `Source.frames` — two consumers tap *different AVF surfaces of the same root* (preview-layer + data-output for capture; player-layer + asset-reader for playback); `Source` stays single-consumer, sibling's `.bufferingNewest(1)` preserved trivially. **Overlay layer:** pure SwiftUI `Canvas` in `ZStack` over the display view, `TimelineView(.animation(minimumInterval: 1.0/60))`, `.drawingGroup()` + `.allowsHitTesting(false)`; macOS parity automatic. **Frame-sync:** results tagged with `Frame.timestamp` → sorted ring buffer (`ResultStore`) → overlay reads `displayTime` at draw, O(log n) lookup of "most-recent result ≤ displayTime"; staleness threshold 500 ms live / 2 s playback; `seek` clears store. Iris ships best-effort lagged overlays in live capture; frame-accurate in playback. **Findings for BRIEF refresh:** `AVSynchronizedLayer` is `AVPlayerItem`-only (no capture variant); fan-out problem dissolves once AVF is framed as two parallel hardware paths off the same root; `videoRect` is load-bearing — thread post-letterbox rect through to overlay. Zero tensions with sibling block.

### 🟡 [project-shape-and-tooling](.blockmaster/blocks/260520-project-shape-and-tooling.md) — Repo layout, test apps, build tooling

exploration · branch main · created 2026-05-20 18:00
Pick-up-here: Scope locked: (1) single-`Package.swift`-with-N-targets vs core + adapter-repos (resolves deferred package-layout question from ecosystem survey), (2) iOS+macOS test app placement (in-repo executable targets vs companion Xcode projects vs separate repos), (3) build tooling chain (formatter, linter, CI, DocC, pre-commit), (4) fixture story. **No researcher dispatched yet** — awaiting user input on methodology (researcher dispatch vs interactive walk-through).
