# Open questions

<!-- Status tags: [open] [exploring] [answered DATE]. File references should be clickable markdown links. -->

## Open

_(none currently)_

## Answered

- [answered 2026-05-21] **`Detector` stateful-conformer shape.** Protocol stays `Sendable`-only; stateful conformers wrap state in an internal `actor` by their own choice. Already covered by the two 2026-05-20 decisions in [`DECISIONS.md`](./DECISIONS.md): "Hot-swap by replacing the instance" + "`@CaptureActor` in `IrisCapture`'s public API". Forcing actor-ness at the protocol level (`AnyObject` etc.) buys no real type-safety since the type system can't tell "actor" from "Sendable class with NSLock" — both are legitimate per the strict-concurrency escape-hatch decision. Ergonomic shape of a stateful actor conformer (call-site overhead crossing the actor boundary) gets validated when the first stateful conformer ships — not in M2's locked scope.
- [answered 2026-05-21] **Package layout fork.** Stay with the current single-target shape; revisit only when adapter packages actually need to grow separately. Covered by the existing 2026-05-20 decision — splitting later is a non-breaking change. See [`DECISIONS.md`](./DECISIONS.md) §"Single SwiftPM target, folder-organized internally".
- [answered 2026-05-20] Async model: `AsyncStream<Frame>` exposed via an `AsyncSequence` protocol, `.bufferingNewest(1)` from day one. See [`DECISIONS.md`](./DECISIONS.md).
- [answered 2026-05-20] Concurrency boundaries: `@CaptureActor` in `IrisCapture` public API; not extended to `Detector`. See [`DECISIONS.md`](./DECISIONS.md).
- [answered 2026-05-20] Hot-swapping Core ML: swap the instance, never mutate in place. `Detector: Sendable`; stateless conformers `struct`, stateful conformers `actor`. See [`DECISIONS.md`](./DECISIONS.md).
- [answered 2026-05-20] macOS overlay parity: SwiftUI `Canvas` + centralized Y-flip + `NormalizedGeometryConverting` protocol with per-source backends. See [`DECISIONS.md`](./DECISIONS.md).
- [answered 2026-05-20] Foundation Models scope: two protocols (`Detector` + `Captioner`); VLM backends conform to both. See [`DECISIONS.md`](./DECISIONS.md).
