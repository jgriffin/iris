# review-prior-projects — Deep-read shortlisted prior projects

parent: [m0-explorations](.blockmaster/blocks/260520-m0-explorations.md)
created: 2026-05-20 10:00
modified: 2026-05-20 10:00
context: .blockmaster/blocks/260520-review-prior-projects.md
kind: research
goal: For each project shortlisted by `survey-dev-folder`, extract reusable patterns, design choices, and gotchas that should inform Iris's M1 capture pipeline.

### Context

Consumes the shortlist produced by [survey-dev-folder](.blockmaster/blocks/260520-survey-dev-folder.md). Stays 📋 until that block closes — its scope depends on the shortlist contents.

### Approach (sketch — refine at open)

For each shortlisted project:

1. Read the capture entry point — how is `AVCaptureSession` set up, configured, started/stopped?
2. Read frame plumbing — `CMSampleBuffer` → app-level type (struct / class / `inout`)? Is there a shared `Frame` shape?
3. Read detection path — Vision request wiring, model load, async pattern (`Task`, completion handler, `AsyncStream`)?
4. Read overlay (if present) — coordinate-space conversion, rotation/mirroring handling?
5. Note 2–3 things worth carrying forward; note 1–2 things worth NOT repeating.

### Output

Per-project notes (likely under `notes/prior-projects/<slug>.md`, or inlined here if short), plus a synthesis section in the Outcome that answers M1 open design questions where the prior art has opinion to offer.

### Pick-up-here

Queued — opens after `survey-dev-folder` closes with shortlist.

### Progress

- 2026-05-20 10:00 — created and queued
