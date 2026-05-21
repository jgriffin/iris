# Open questions

<!-- Status tags: [open] [exploring] [answered DATE]. File references should be clickable markdown links. -->

## Open

- [open] **Sidecar dataset format.** COCO JSON vs YOLO vs Pascal VOC vs Create ML JSON. No prior-art signal — decide on domain merits before locking M5 plans. Create ML JSON is the iOS-native dark horse: round-trips into Create ML, Apple-blessed.
- [open] **Package layout fork.** Current shape is a single SwiftPM target with folder-organized internal modules. Kadr's lived experience says core single-target + adapter packages as separate repos (e.g. `iris-overlay`, `iris-dataset`, `iris-tuning`) is the better unit once adapters grow. Worth a conscious call before M4 or M5 plans add their own dependencies.
- [open] **`Detector` stateful-conformer shape.** Whether the protocol requires `actor` for stateful conformers, or whether `Sendable` + conformer's internal choice of `actor`-vs-class is sufficient. Tentative lean: protocol stays `Sendable`-only; stateful conformers use `actor` internally. Validate at M2.

## Answered

- [answered 2026-05-20] Async model: `AsyncStream<Frame>` exposed via an `AsyncSequence` protocol, `.bufferingNewest(1)` from day one. See [`DECISIONS.md`](./DECISIONS.md).
- [answered 2026-05-20] Concurrency boundaries: `@CaptureActor` in `IrisCapture` public API; not extended to `Detector`. See [`DECISIONS.md`](./DECISIONS.md).
- [answered 2026-05-20] Hot-swapping Core ML: swap the instance, never mutate in place. `Detector: Sendable`; stateless conformers `struct`, stateful conformers `actor`. See [`DECISIONS.md`](./DECISIONS.md).
- [answered 2026-05-20] macOS overlay parity: SwiftUI `Canvas` + centralized Y-flip + `NormalizedGeometryConverting` protocol with per-source backends. See [`DECISIONS.md`](./DECISIONS.md).
- [answered 2026-05-20] Foundation Models scope: two protocols (`Detector` + `Captioner`); VLM backends conform to both. See [`DECISIONS.md`](./DECISIONS.md).
