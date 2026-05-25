# Questions driving this exploration

M5·P1 — Vision capability audit. Feeds the P2 capability model and the
P3/P4 honest overlays + inspector. Plan: [`plans/features/M5-honest-detectors.md`](../../plans/features/M5-honest-detectors.md).

## Primary question

- For each **built-in** Vision detector (the new Swift value-type API,
  `DetectRectanglesRequest` / `RectangleObservation` generation — *not* the
  legacy `VNImageRequestHandler` / `VNRequest` API), what does it actually
  **produce** and **expose**? Specifically:
  - What is the **output geometry** — box / quad / keypoints(skeleton) / mask /
    heatmap / contour / label-only / scalar?
  - Does the observation carry **real (probabilistic) confidence**, **per-element**
    confidence, or **none** (a geometric/derived value such as the constant `1.0`
    rectangles report)?
  - What request properties are **genuinely tunable** (vs. cosmetic, or absent)?

## Sub-questions

- Which detectors expose *nothing* tunable, and which report a confidence that
  isn't a probability? These are the cases that justify the honest-UI design —
  the matrix must make them explicit.
- What is the right set of **capability axes** for the P2 model — derived from
  what actually *varies* across the matrix, not invented up front?
- Is **human body pose** a good second exemplar alongside reworked rectangles
  (rich keypoints + real per-joint confidence vs. rectangles' none)? Or would a
  different detector prove the capability model better?
- Which detectors are **traps** — deprecated, entitlement-gated, macOS-unavailable,
  hardware-dependent, or otherwise costly to wire as an exemplar?
- Where exactly is the **boundary**: built-in Vision has no general object-box
  detector — confirm and state it (that's Core ML / YOLO, M6).
