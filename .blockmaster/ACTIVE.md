---
blocks_version: 1
---

# Active

## 🟡 [m0-explorations](.blockmaster/blocks/260520-m0-explorations.md) — Upfront explorations before code starts

milestone · branch main · created 2026-05-20 · 0 active children · 3 recently closed
Pick-up-here: **All three children closed.** In-house prior-art (`survey-dev-folder` → `review-prior-projects`) and external ecosystem (`survey-swift-ecosystem` → `search-swift-packages` + `deep-dive-swift-packages`) arcs complete. Deliverables under `explorations/{prior-projects,swift-ecosystem}/`. **M0 ready to close** — optionally after a `BRIEF.md` refresh pass folding in resolved questions (Q1 async, Q2 `@CaptureActor`, Q4 hot-swap, Q5 macOS parity, Q6 Foundation Models) + new package-layout fork (single-package vs core + adapter-repos) + M1-scope additions surfaced in `RECOMMENDATIONS.md`. Then M1 capture planning.

### ✅ [survey-dev-folder](.blockmaster/blocks/260520-survey-dev-folder.md) — Survey ~/dev/ for camera / capture / detection prior art

research · closed 2026-05-20
Outcome: Shortlist of 5 deep-read candidates (PR/ios-videoCapture, PR/PRVisionSpike, ml/yolo-ios-app, ml/sportvision, pocketRadar/BuildingAFeatureRichApp…). Full sweep covered 24 top-level folders + 5 recursed category folders; 9 had signal, 4 low-value entries dropped.

### ✅ [review-prior-projects](.blockmaster/blocks/260520-review-prior-projects.md) — Deep-read shortlisted prior projects

research · closed 2026-05-20
Outcome: 5 per-project notes + `SYNTHESIS.md` (verdicts on `BRIEF.md`'s 6 M1 open questions) + `RECOMMENDATIONS.md` (actionable patterns with code pointers) under `explorations/prior-projects/`. Strong verdicts: `@CaptureActor` in `IrisCapture` public API; SwiftUI `Canvas` overlay with one centralized Y-flip gives macOS parity for free; `Detector` is a `Sendable` protocol with mixed `struct`/`actor` conformers, hot-swap by replacing the instance, `VNCoreMLModel` cached outside detectors. 7 additions proposed for M1 scope (most notably `Detector.warmup()`, letterbox/pillarbox alignment, `.bufferingNewest(1)` back-pressure, `Frame.timestamp` first-class). Still open: COCO vs YOLO sidecar; Foundation Models scope; `Source` protocol unification; cancellation policy.

### ✅ [survey-swift-ecosystem](.blockmaster/blocks/260520-survey-swift-ecosystem.md) — Survey the wider Swift package ecosystem

research · closed 2026-05-20
Outcome: Both children closed. SHORTLIST + 5 external-package deep reads under `explorations/swift-ecosystem/`; recommendations appended to `explorations/prior-projects/RECOMMENDATIONS.md`. Verdicts: AVCam **Borrow**, NextLevel **Study-then-diverge**, MijickCamera **Study-then-diverge**, Kadr **Borrow structurally**, PrivateFoundationModels **Study-then-diverge**. Resolutions: Q6 (two protocols `Detector` + `Captioner`), Source-protocol unification (yes, do it), `DetectorCache` (injectable instance), cancellation (`AsyncStream` + consumer-owned task). New open question raised: package layout (single-package vs core + adapter-repos). 15+ new patterns to lift; ~12 new M1-scope additions.
