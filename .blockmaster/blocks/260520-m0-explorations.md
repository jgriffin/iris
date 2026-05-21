# m0-explorations — Upfront explorations before code starts

parent: roadmap
created: 2026-05-20 10:00
modified: 2026-05-20 (survey closed; review-prior-projects opened)
context: .blockmaster/blocks/260520-m0-explorations.md
kind: milestone
goal: Harvest reusable patterns from prior camera / capture / detection work in `~/dev/` and lock design defaults for M1 before code lands.

### Context

A milestone-block holding pre-code research that sets defaults for the Iris build. The user has done camera + ML pipeline work across several projects scattered through `~/dev/`; before M1 opens (`IrisCapture` + `CameraPreview` + frame stream), we want to surface patterns, idioms, and gotchas worth carrying forward.

This block coordinates the child research blocks and writes the Outcome that should inform M1's open design questions:

- `AsyncStream<Frame>` vs an `AsyncSequence` protocol (BRIEF open question #1)
- Explicit actor isolation (`@CaptureActor`) in the public API (#2)
- Coordinate-space conventions for overlay code (#5)

Branch is `main` for now — work is read-only research with no code changes to isolate. If a follow-on design block needs a code branch, open it on `m0-explorations` per the milestone-block pattern.

### Children

- [survey-dev-folder](.blockmaster/blocks/260520-survey-dev-folder.md) — ✅ closed; produced 5-project shortlist
- [review-prior-projects](.blockmaster/blocks/260520-review-prior-projects.md) — ✅ closed; SYNTHESIS + RECOMMENDATIONS landed
- [survey-swift-ecosystem](.blockmaster/blocks/260520-survey-swift-ecosystem.md) — ✅ closed; SHORTLIST + 5 external-package deep reads landed; recommendations rolled into the project RECOMMENDATIONS
- [runtime-pipeline-architecture](.blockmaster/blocks/260520-runtime-pipeline-architecture.md) — ✅ closed; 20 locked decisions, Q1 + Q2 resolved
- [display-pipeline-architecture](.blockmaster/blocks/260520-display-pipeline-architecture.md) — ✅ closed; 27 locked decisions; display surface, fan-out, overlay layer, frame-sync all resolved
- [project-shape-and-tooling](.blockmaster/blocks/260520-project-shape-and-tooling.md) — 🟡 active; repo layout, iOS+macOS test apps, build tooling chain, fixture story (no researcher dispatched yet)

### Pick-up-here

Both architecture sibling blocks closed; BRIEF.md updated with an "Architecture references" section pointing at both `SYNTHESIS.md` + `RECOMMENDATIONS.md` files (discoverability only — findings stay in the exploration files, not duplicated in the brief). Sixth child [project-shape-and-tooling](.blockmaster/blocks/260520-project-shape-and-tooling.md) 🟡 now active — covers the deferred package-layout question, iOS+macOS test apps, and build tooling. **No researcher dispatched yet** — awaiting user input on methodology (researcher dispatch vs interactive walk-through). After it closes: M0 ready to close, optionally after a BRIEF.md full refresh pass folding in all accumulated verdicts (Q1 async, Q2 actor, Q4 hot-swap, Q5 macOS parity, Q6 Foundation Models + the 3 runtime-pipeline + 3 display-pipeline surprises + package-layout decision + the M1-scope additions across all five children). Then M1 capture planning.

### Progress

- 2026-05-20 10:00 — created; two child research blocks set up (survey 🟡, review 📋)
- 2026-05-20 — `survey-dev-folder` closed with 5-project shortlist; `review-prior-projects` opened with concrete scope
- 2026-05-20 — `review-prior-projects` closed; SYNTHESIS + RECOMMENDATIONS under `explorations/prior-projects/`
- 2026-05-20 14:00 — third child `survey-swift-ecosystem` opened (with nested `search-swift-packages` / `deep-dive-swift-packages`) to scan the external package ecosystem before BRIEF.md is refreshed
- 2026-05-20 — `survey-swift-ecosystem` ✅ closed with SHORTLIST + 5 deep reads + appended recommendations. All three breadth-pass children done.
- 2026-05-20 16:00 — fourth child [runtime-pipeline-architecture](.blockmaster/blocks/260520-runtime-pipeline-architecture.md) opened (synthesis-focused; source-side performance + isolation; detector internals + dataset + sidecar out of scope)
- 2026-05-20 — `runtime-pipeline-architecture` ✅ closed. Q1 locked (concrete `AsyncStream<Frame>` via `Source` protocol). Q2 locked (actor instance + custom serial executor, no `@globalActor`). 20 decisions + 11 M1 additions + 12 anti-patterns + 6 deferred. Three BRIEF.md surprises to surface at refresh.
- 2026-05-20 17:00 — fifth child [display-pipeline-architecture](.blockmaster/blocks/260520-display-pipeline-architecture.md) opened to cover the rendering / preview / overlay / frame-sync layer.
- 2026-05-20 — `display-pipeline-architecture` ✅ closed. 27 locked decisions. `AVPlayer`+`AVPlayerLayer` for playback display. Display does NOT consume `Source.frames` — two parallel AVF hardware paths off the same root; sibling's `.bufferingNewest(1)` preserved trivially. SwiftUI `Canvas` overlay in `ZStack` with `TimelineView`. `Frame.timestamp`-tagged results + `ResultStore` ring buffer + binary-search lookup by `displayTime`. Best-effort lagged overlays in live capture; frame-accurate in playback. Zero tensions with sibling.
- 2026-05-20 — BRIEF.md updated with "Architecture references" section linking both architecture explorations (`SYNTHESIS.md` + `RECOMMENDATIONS.md` for both runtime-pipeline + display-pipeline) and the cross-cutting prior-art rollup. References only — no findings duplicated.
- 2026-05-20 18:00 — sixth child [project-shape-and-tooling](.blockmaster/blocks/260520-project-shape-and-tooling.md) opened to cover repo layout, iOS+macOS test apps, and build tooling chain. No researcher dispatched yet — awaiting user input on methodology.
