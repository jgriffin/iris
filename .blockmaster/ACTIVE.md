---
blocks_version: 1
---

# Active

## 🟡 [m0-explorations](.blockmaster/blocks/260520-m0-explorations.md) — Upfront explorations before code starts

milestone · branch main · created 2026-05-20 · 1 active child · 1 recently closed
Pick-up-here: `survey-dev-folder` ✅ closed with a 5-project shortlist; `review-prior-projects` 🟡 now in flight against that shortlist. Close M0 when `review-prior-projects` closes.

### ✅ [survey-dev-folder](.blockmaster/blocks/260520-survey-dev-folder.md) — Survey ~/dev/ for camera / capture / detection prior art

research · closed 2026-05-20
Outcome: Shortlist of 5 deep-read candidates (PR/ios-videoCapture, PR/PRVisionSpike, ml/yolo-ios-app, ml/sportvision, pocketRadar/BuildingAFeatureRichApp…). Full sweep covered 24 top-level folders + 5 recursed category folders; 9 had signal, 4 low-value entries dropped.

### 🟡 [review-prior-projects](.blockmaster/blocks/260520-review-prior-projects.md) — Deep-read shortlisted prior projects

research · opened 2026-05-20
Pick-up-here: Walk the 5 shortlisted projects in priority order (ios-videoCapture → PRVisionSpike → yolo-ios-app → sportvision → pocketRadar). For each: capture-entrypoint shape, Frame plumbing, detection-path async pattern, overlay coord-space handling. Land 2–3 carry-forwards + 1–2 anti-patterns per project. Synthesis section addresses M1 open design questions where prior art has opinion.
