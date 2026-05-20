---
blocks_version: 1
---

# Active

## 🟡 [m0-explorations](.blockmaster/blocks/260520-m0-explorations.md) — Upfront explorations before code starts

milestone · branch main · created 2026-05-20 · 1 active child · 2 recently closed
Pick-up-here: In-house prior-art arc done (`survey-dev-folder` ✅ → `review-prior-projects` ✅, deliverables under `explorations/prior-projects/`). New nested arc opened to scan the *external* Swift package ecosystem: `survey-swift-ecosystem` 🟡 with `search-swift-packages` 🟡 in flight and `deep-dive-swift-packages` 📋 queued. Close M0 once that arc lands. Then BRIEF.md refresh, then M1 capture planning.

### ✅ [survey-dev-folder](.blockmaster/blocks/260520-survey-dev-folder.md) — Survey ~/dev/ for camera / capture / detection prior art

research · closed 2026-05-20
Outcome: Shortlist of 5 deep-read candidates (PR/ios-videoCapture, PR/PRVisionSpike, ml/yolo-ios-app, ml/sportvision, pocketRadar/BuildingAFeatureRichApp…). Full sweep covered 24 top-level folders + 5 recursed category folders; 9 had signal, 4 low-value entries dropped.

### ✅ [review-prior-projects](.blockmaster/blocks/260520-review-prior-projects.md) — Deep-read shortlisted prior projects

research · closed 2026-05-20
Outcome: 5 per-project notes + `SYNTHESIS.md` (verdicts on `BRIEF.md`'s 6 M1 open questions) + `RECOMMENDATIONS.md` (actionable patterns with code pointers) under `explorations/prior-projects/`. Strong verdicts: `@CaptureActor` in `IrisCapture` public API; SwiftUI `Canvas` overlay with one centralized Y-flip gives macOS parity for free; `Detector` is a `Sendable` protocol with mixed `struct`/`actor` conformers, hot-swap by replacing the instance, `VNCoreMLModel` cached outside detectors. 7 additions proposed for M1 scope (most notably `Detector.warmup()`, letterbox/pillarbox alignment, `.bufferingNewest(1)` back-pressure, `Frame.timestamp` first-class). Still open: COCO vs YOLO sidecar; Foundation Models scope; `Source` protocol unification; cancellation policy.

### 🟡 [survey-swift-ecosystem](.blockmaster/blocks/260520-survey-swift-ecosystem.md) — Survey the wider Swift package ecosystem

research · branch main · opened 2026-05-20 14:00
Pick-up-here: Two-phase nested arc. `search-swift-packages` 🟡 in flight (two agents dispatched across SwiftPackageIndex / GitHub topics + curated lists / web); `deep-dive-swift-packages` 📋 queued, scope set by search outcome. Output lives in `explorations/swift-ecosystem/`. Outcome augments `explorations/prior-projects/RECOMMENDATIONS.md`.

#### 🟡 [search-swift-packages](.blockmaster/blocks/260520-search-swift-packages.md) — Scan SwiftPackageIndex, GitHub, curated lists, and the recent web for candidates

research · opened 2026-05-20 14:00
Pick-up-here: Agents writing raw findings to `explorations/swift-ecosystem/raw/<agent>.md`. Synthesize into `SHORTLIST.md` when they return. Target 8–15 packages across the six Iris module areas. Don't re-surface the 5 already-read in-house projects.

#### 📋 [deep-dive-swift-packages](.blockmaster/blocks/260520-deep-dive-swift-packages.md) — Deep-read shortlisted external packages

research · queued 2026-05-20 14:00
Opens after `search-swift-packages` closes with a shortlist. Same four lenses as `review-prior-projects` plus a public-API-shape lens; go/no-go recommendation per package (use / borrow / study-then-diverge / ignore).
