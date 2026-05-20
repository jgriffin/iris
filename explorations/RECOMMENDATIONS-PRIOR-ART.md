# Recommendations — prior art (rollup)

**Date:** 2026-05-20

Cross-cutting decisions for Iris distilled from two exploration arcs. This file is the **decision layer** for `BRIEF.md` — what should be folded in before M1 plans lock. Pattern lists and full evidence live in the per-arc files; this rollup avoids duplicating them.

**Sources:**
- In-house projects in `~/dev/` — [`prior-projects/RECOMMENDATIONS.md`](./prior-projects/RECOMMENDATIONS.md) (full per-source notes alongside: `ios-videoCapture.md`, `PRVisionSpike.md`, `yolo-ios-app.md`, `sportvision.md`, `action-and-vision.md`).
- External Swift package ecosystem — [`swift-ecosystem/RECOMMENDATIONS.md`](./swift-ecosystem/RECOMMENDATIONS.md) (full per-source notes alongside: `apple-avcam.md`, `nextlevel.md`, `mijick-camera.md`, `kadr.md`, `private-foundation-models.md`).

---

## M1 question resolutions (rolled up)

| # | Question | Status | Decision | Strongest evidence |
|---|---|---|---|---|
| **Q1** | Async model | ✅ Resolved | `AsyncStream<Frame>` exposed via an `AsyncSequence` protocol, `.bufferingNewest(1)` from day one | In-house: 3 of 5 projects shipped without back-pressure and paid for it; External: NextLevel's per-frame `Task` + `NSLock` accounting confirms the anti-pattern |
| **Q2** | `@CaptureActor` in public API | ✅ Resolved | Yes — `actor` with `nonisolated unownedExecutor` bound to a `DispatchSerialQueue`, `nonisolated let previewSource` as the only opening | External: Apple AVCam `CaptureService.swift:14` is *the* working blueprint |
| **Q3** | Canonical sidecar format | 🟡 **Still open** | Decide on domain merits; options are COCO, YOLO, **Create ML JSON** (third option added during ecosystem scan) | sportvision (YOLO) is the only data point; everyone else punts |
| **Q4** | Hot-swap Core ML — value vs reference, mutate vs replace | ✅ Resolved | **Swap the instance, never mutate in place.** `Detector: Sendable` protocol; stateless conformers can be `struct`, stateful (e.g. trajectory) are `actor`. `VNCoreMLModel` cached *outside* the detector so swap is cheap | In-house: yolo-ios-app's `setModel`, PRVisionSpike's tear-and-replace; External: PFM's snapshot-at-construction |
| **Q5** | macOS overlay parity | ✅ Resolved | Pure SwiftUI `Canvas` + one centralized Y-flip + `NormalizedGeometryConverting`-style protocol with per-source backends. Forbid `UIDevice.current.orientation` and any `UIBezierPath`/`NSBezierPath` | In-house: sportvision's `DetectionOverlayView.swift` works unchanged on both platforms (170 LOC, zero `#if os`); ActionAndVision's `NormalizedGeometryConverting` protocol is the seam |
| **Q6** | Foundation Models scope | ✅ Resolved | **Two protocols** — `Detector` (image → `[Detection]`) and `Captioner` (image → text). VLM backends conform to both, not one merged super-protocol | External: PFM's `EmbeddingBackend` / `LanguageModelBackend` split with the explicit rationale "input/output shapes don't overlap" |
| **+** | `Source`-protocol unification upstream of `IrisCapture`/`IrisPlayback` | ✅ Resolved | Yes — small protocols that decouple producers from consumers | External: Apple AVCam's `OutputService` + `PreviewSource`; NextLevel as the negative example (delegate-only frames lock consumers to AVCaptureSession semantics) |
| **+** | `DetectorCache` ownership | ✅ Resolved | Injectable instance per pipeline/session, not a singleton | External: PFM's snapshot-at-construction + AVCam's `DeviceLookup` as `private let` |
| **+** | Cancellation policy | ✅ Resolved | `AsyncStream` + consumer-owned task lifetime + structured `Task` parent/child cancellation. **No per-frame `Task` spawn inside the framework** | External: NextLevel's hand-rolled `_activeTasks: [Task<Void, Never>]` + `NSLock` is the concrete cost of getting it wrong |
| **NEW** | **Package layout** | 🔴 **Open fork** | Decide before any `Package.swift` is written | External: Kadr's lived experience says **core single-target package + adapter packages as separate repos** beats single-package multi-target |

## Headline decisions to fold into BRIEF.md

The four that change BRIEF.md's existing shape:

1. **Resolve open questions Q1, Q2, Q4, Q5, Q6** with the decisions above. Add the resolved `Source`/`DetectorCache`/cancellation calls alongside.
2. **Add the package-layout fork as a `BRIEF.md` open question that must be decided before M1.** Default lean: **core `iris` + separate adapter repos (`iris-overlay`, `iris-dataset`, `iris-tuning`)**, per Kadr's lived experience. The benefits are real (per-package platform requirements, independent semver, third-party deps confined to the adapter that needs them) but it's a structural change worth a conscious decision rather than drifting into.
3. **Add Create ML JSON as a third Q3 option** alongside COCO and YOLO. Apple-blessed, round-trips into Create ML, iOS-native — relevant since Iris is iOS/macOS-only.
4. **Adopt `@preconcurrency import AVFoundation` + `@unchecked Sendable + NSLock + documented invariant`** as the legitimate Swift 6 strict-concurrency escape hatches for AVFoundation/Vision/CoreML types. Apple's own AVCam uses the former; Kadr's `CancellationToken` is the canonical template for the latter. The Swift 6 strict-concurrency story is *not* "all reference types become actors."

## Cross-cutting principles (both arcs independently agreed)

These showed up in both the in-house and external reads — high-confidence project-wide principles:

- **macOS parity is a *principle*, not a target.** Files compile *and render correctly* on iOS and macOS from the moment written. (In-house: sportvision proves it works; ios-videoCapture proves what fails when it's declarative-only. External: HaishinKit is the only Swift package with serious cross-platform AVCaptureSession — validates Iris's "no macOS camera capture" scope.)
- **Swap the instance, never mutate in place.** Hot-swap = construct fresh, replace the reference. (In-house: yolo-ios-app, PRVisionSpike. External: PFM.)
- **`AsyncStream<Frame>` is the contract; package the per-frame stream that nobody else has.** Three in-house and three external projects either lack frame streams or have broken back-pressure. Iris's contribution is the packaging, not the architecture.
- **Strict concurrency without false escape hatches.** Forbid `@unchecked Sendable` *without* a documented locking invariant; allow `@unchecked Sendable + NSLock + doc-comment`. Forbid bridging actor state to MainActor via Combine `@Published`+`.values` (AVCam's retrofit smell — Iris is greenfield, no Combine).
- **Public API vends Iris-owned value types — no AVFoundation/UIKit leak.** (In-house: ios-videoCapture is the negative example with `AnyPublisher<AVCaptureDevice>` in protocols. External: MijickCamera's `CameraManager` has no public init purely to hide AVKit.)
- **`@CaptureActor` in public API for capture; do not extend to `Detector`.** (In-house: ios-videoCapture's `dispatchPrecondition(.onQueue(sessionQueue))` discipline is the working blueprint. External: AVCam's actor with custom serial executor is the concrete shape.)

## Where to read more

- **For pattern lists with file:line pointers:** `prior-projects/RECOMMENDATIONS.md` and `swift-ecosystem/RECOMMENDATIONS.md`. They share structural shape (principles, patterns, M1 scope additions, anti-patterns, still-open) but the entries are evidence-grounded in their respective sources.
- **For per-source deep reads:** the 10 individual `.md` files across the two subfolders. Each has Verdict, Carry-forward, Don't-repeat, and Opinions-on-open-questions sections.
- **For the synthesis behind the in-house verdicts on Q1/Q2/Q4/Q5:** `prior-projects/SYNTHESIS.md` — the long-form reasoning that produced the in-house recommendations.
- **For the candidate-discovery audit trail:** `swift-ecosystem/SHORTLIST.md` plus its two `raw/` source files — the SwiftPackageIndex / GitHub / curated-list / web walk that produced the deep-read shortlist.
