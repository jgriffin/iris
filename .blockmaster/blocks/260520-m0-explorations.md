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

### Pick-up-here

All three children closed. M0 is ready to close. Recommended next move: optional `BRIEF.md` refresh pass folding in (a) the resolved open questions (Q1 async, Q2 `@CaptureActor`, Q4 hot-swap, Q5 macOS parity, Q6 Foundation Models), (b) the package-layout decision (single-package vs core + adapter-repos), and (c) the M1-scope additions surfaced in `RECOMMENDATIONS.md`. Then close M0 and move to M1 capture planning.

### Progress

- 2026-05-20 10:00 — created; two child research blocks set up (survey 🟡, review 📋)
- 2026-05-20 — `survey-dev-folder` closed with 5-project shortlist; `review-prior-projects` opened with concrete scope
- 2026-05-20 — `review-prior-projects` closed; SYNTHESIS + RECOMMENDATIONS under `explorations/prior-projects/`
- 2026-05-20 14:00 — third child `survey-swift-ecosystem` opened (with nested `search-swift-packages` / `deep-dive-swift-packages`) to scan the external package ecosystem before BRIEF.md is refreshed
- 2026-05-20 — `survey-swift-ecosystem` ✅ closed with SHORTLIST + 5 deep reads + appended recommendations. All three M0 children done.
