---
blocks_version: 1
---

# Active

## 🟡 [m0-explorations](.blockmaster/blocks/260520-m0-explorations.md) — Upfront explorations before code starts

milestone · branch main · created 2026-05-20 · 0 active children · 4 recently closed (display-pipeline opens momentarily)
Pick-up-here: Data-plane synthesis closed (`runtime-pipeline-architecture` ✅, Q1 + Q2 locked). Sibling [display-pipeline-architecture](.blockmaster/blocks/260520-display-pipeline-architecture.md) opening now — covers preview/player rendering, overlay layering, source fan-out without violating `.bufferingNewest(1)`, and detector→overlay frame sync. After that closes: M0 ready to close, optionally after `BRIEF.md` refresh pass folding in resolved questions (Q1 async, Q2 actor, Q4 hot-swap, Q5 macOS parity, Q6 Foundation Models) + display-side locked decisions + package-layout fork + accumulated M1-scope additions. Then M1 capture planning.

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

### 🟡 [display-pipeline-architecture](.blockmaster/blocks/260520-display-pipeline-architecture.md) — Display pipeline: preview, player, overlay, frame sync

exploration · branch main · created 2026-05-20 17:00
Pick-up-here: Sibling to data-plane block. Resolves display surface choice (`AVCaptureVideoPreviewLayer` for capture; `AVPlayer`+`AVPlayerLayer` vs `AVSampleBufferDisplayLayer` for playback), source fan-out without breaking `.bufferingNewest(1)`, overlay layer choice + macOS parity, and detector→overlay frame sync. Researcher dispatch incoming.
