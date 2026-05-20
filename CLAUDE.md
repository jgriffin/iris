@~/.claude/skills/blockmaster/blockmaster.md

# Iris

Swift package providing the shared scaffolding for camera + ML vision apps on
Apple platforms: capture, playback, inference, overlays, tuning, and dataset
capture. Individual downstream projects depend on Iris and focus only on their
specific detection problem.

**Read [`BRIEF.md`](./BRIEF.md) for the full design intent, principles, and
milestone path.** This file is the operating contract for working in the repo.

## Platform baseline

- **iOS / iPadOS 26** — full feature set (capture, playback, inference, dataset).
- **macOS 26** — playback, inference, overlay, dataset. **No camera capture on
  macOS.** Mac is a model-evaluation and dataset-curation target.
- **Swift 6 language mode, strict concurrency on.** Don't downgrade to relax the
  checker — fix the design instead.
- **SwiftUI-first.** UIKit and AVFoundation live behind `UIViewRepresentable`
  and protocol boundaries; they should not leak into the public API.
- **`async/await` end to end.** No completion handlers. No Combine unless there
  is a concrete reason (state it in the diff).

## Architecture at a glance

Six modules, each a SwiftPM target:

| Module           | Platforms     | Role                                                         |
| ---------------- | ------------- | ------------------------------------------------------------ |
| `IrisCapture`    | iOS only      | AVCaptureSession + `CameraPreview` + `AsyncStream<Frame>`    |
| `IrisPlayback`   | iOS + macOS   | AVAssetReader-backed `Frame` stream, scrubber, frame-step    |
| `IrisDetection`  | iOS + macOS   | `Detector` protocol; Vision / Core ML / Foundation Models    |
| `IrisOverlay`    | iOS + macOS   | SwiftUI views drawing `[Detection]`; coordinate-space mgmt   |
| `IrisTuning`     | iOS + macOS   | `@Observable` filter/threshold controls, "what-if" mode      |
| `IrisDataset`    | iOS + macOS   | One-tap frame + COCO-JSON sidecar to a pluggable sink        |

**Cross-cutting invariants:**

- `Frame` is source-agnostic. Capture and playback feed the *same* downstream
  pipeline. Detector and overlay code should not branch on where a frame came
  from.
- `Detector` is `Sendable` and async. New backends slot in by conforming.
- Coordinate-space conversion (Vision normalized ↔ view coords, rotation,
  mirroring) is centralized in `IrisOverlay`. Do not re-derive it in callers.

## Conventions

- **Public API is SwiftUI-shaped.** If a public type forces a consumer to import
  UIKit or AVFoundation, that's a smell — wrap it.
- **Tests live alongside their target** in `Tests/<Module>Tests/`. Use real
  fixtures (sample video clips, sample `MLModel`s) in
  `Tests/<Module>Tests/Fixtures/`, not mocks, wherever it's tractable.
- **Static visual previews** for any view that draws detections — small HTML or
  SwiftUI `#Preview` cases with known detection inputs, so visual regressions
  show up without running a full demo app. See the user's "favorite pattern"
  note in global CLAUDE.md for why.
- **Don't commit datasets, captured video, or compiled `.mlmodelc/`.** The
  `.gitignore` already covers these; keep new outputs under `datasets/`,
  `captures/`, or `*.mov`/`*.mp4` so they stay out.
- **Package.resolved is gitignored** (library convention). If Iris ever ships a
  demo app target that pins versions, revisit this for that target only.

## Open design questions

These are unresolved as of the brief and should be settled *before* the
relevant module is built, not after:

1. `AsyncStream<Frame>` vs. exposing through an `AsyncSequence` protocol.
2. Explicit actor isolation in the public API (e.g. a `@CaptureActor`).
3. COCO JSON as canonical sidecar format (vs. YOLO / Pascal VOC).
4. Hot-swapping a Core ML model: tear down vs. swap detector instance →
   determines whether `Detector` is value or reference type.
5. macOS overlay parity (coordinate spaces, gestures).
6. Foundation Models: a `Detector` backend, a separate `Captioner` protocol,
   or both.

When you hit one of these in a task, surface it rather than silently picking.

## Milestone path

M1 Capture → M2 Detection+Overlay → M3 Playback (first macOS target) →
M4 Tuning → M5 Dataset → M6 Custom models + captioning. See `BRIEF.md` for the
per-milestone detail.

## Working norms for this repo

- New code should compile under Swift 6 strict concurrency on first try. If
  it doesn't, the design is the bug.
- Prefer protocol + adapter over conditional compilation for
  iOS-vs-macOS divergence. `#if os(iOS)` is fine for *implementation* details
  inside a module, not for public API shape.
- When adding a new detector or sink, add a fixture-based test in the same
  commit. The point of Iris is reuse — untested adapters defeat that.
