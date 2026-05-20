# m0-explorations — Upfront explorations before code starts

parent: roadmap
created: 2026-05-20 10:00
modified: 2026-05-20 10:00
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

- [survey-dev-folder](.blockmaster/blocks/260520-survey-dev-folder.md) — 🟡 sweep `~/dev/`, produce shortlist of candidates
- [review-prior-projects](.blockmaster/blocks/260520-review-prior-projects.md) — 📋 deep-read shortlisted candidates, extract patterns

### Pick-up-here

`survey-dev-folder` 🟡 is the active leaf. Once it closes with a shortlist, `review-prior-projects` opens against that list. Close M0 when both children close; the Outcome should answer at minimum BRIEF open questions #1, #2, #5.

### Progress

- 2026-05-20 10:00 — created; two child research blocks set up (survey 🟡, review 📋)
