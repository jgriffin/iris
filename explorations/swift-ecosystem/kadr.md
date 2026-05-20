# Kadr — prior-art read

**Path:** github.com/SteliyanH/kadr · 41★ · iOS 16+/macOS 13+/tvOS 16+/visionOS 1+ · Swift 6.0 · Apache 2.0
**Companion packages:** kadr-ui, kadr-captions, kadr-photos (all separate SPM packages, all read at lower depth)
**Read date:** 2026-05-20
**Priority lens:** architectural template — multi-target SPM with companion adapter packages, Swift 6 strict-concurrency throughout

## At a glance

Kadr is a declarative DSL for video composition (`Video { VideoClip(...); Transition.dissolve(...) }.export(to:)`) on top of AVFoundation. Domain is unrelated to Iris (video editing vs. CV pipeline), but the **shape** is the closest prior art available: Swift 6 strict-concurrency from day one, async/await throughout, zero third-party deps, and — critically — a "core engine + three external adapter packages" split that maps almost 1:1 onto Iris's `IrisDetection`-core plus `IrisOverlay`/`IrisDataset`/`IrisTuning` plan.

Codebase size: core `Sources/Kadr/` has 11 subfolders (DSL, Engine, Animation, Export, Filters, Layout, Modifiers, Overlays, Platform, Time, Errors), ~15 files in `Engine/`, ~14 in `DSL/`. v0.12.0 at read time, 467+ tests, on the runway to v1.0 semver lock.

## Package shape

The core `Package.swift` is **strikingly minimal** — a single target, single product, no resources, no conditional platforms:

```swift
// swift-tools-version: 6.0
let package = Package(
    name: "Kadr",
    platforms: [.iOS(.v16), .macOS(.v13), .tvOS(.v16), .visionOS(.v1)],
    products: [.library(name: "Kadr", targets: ["Kadr"])],
    targets: [
        .target(
            name: "Kadr",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(name: "KadrTests", dependencies: ["Kadr"], resources: [.process("Resources")]),
    ]
)
```

That `.enableExperimentalFeature("StrictConcurrency")` + `.swiftLanguageMode(.v6)` pair appears on **every target across all four packages** — the project's universal concurrency switch. `Examples/` is a top-level folder of `.swift` showcase files that are NOT a build target — they're documentation pinned by the test target on compile via copies. `.gitignore`s `Package.resolved` (library convention).

Internal structure is folder-based, not target-based: `Sources/Kadr/{DSL,Engine,Animation,Export,Overlays,Platform,Time,...}`. Public DSL types live in `DSL/`; the AVFoundation-touching guts in `Engine/`. No `internal` SPM target enforcing the boundary — it's purely convention + access modifiers.

## Async / concurrency story

Every public value type is `Sendable`. The core `Clip` protocol declares it:

```swift
public protocol Clip: Sendable {
    var duration: CMTime { get }
    var clipID: ClipID? { get }
    var startTime: CMTime? { get }
    var transform: Transform? { get }
    // ...
}
```

The top-level `Video` is `public struct Video: Sendable` with `let` fields throughout. Builders use `@resultBuilder public enum VideoBuilder`. Closures crossing the API boundary are explicitly `@Sendable @escaping`. Custom compositor protocol: `public protocol Compositor: Sendable { func process(image: CIImage, context: CompositorContext) -> CIImage }` — **synchronous**, with the engine wrapping in `applyingCIFiltersWithHandler` for the async finish (per-frame `async` is explicitly called out as a footgun).

Progress reporting via `AsyncThrowingStream` (`exporter.run()` returns one). No `Combine`. No completion handlers in public API.

**No custom global actors.** No `@MainActor` on public surface — that's a UI concern (kadr-ui handles it). `nonisolated static` helpers are scattered through both core and UI for "pure math runnable in any context" — `nonisolated static func bucketPeaks(...)` etc.

## Multi-target adapter pattern (priority lens)

**This is the load-bearing pattern for Iris.** Kadr is the core package; `kadr-ui`, `kadr-captions`, `kadr-photos` are **three completely separate Swift packages**, each in its own GitHub repo, each with its own `Package.swift`, version, CHANGELOG, ROADMAP, and DESIGN doc. They depend on `kadr` via SPM:

```swift
// kadr-ui/Package.swift
dependencies: [
    .package(url: "https://github.com/SteliyanH/kadr.git", from: "0.11.0"),
    .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.18.0"),  // test-only
    .package(url: "https://github.com/nalexn/ViewInspector", from: "0.10.0"),                // test-only
],
targets: [
    .target(name: "KadrUI", dependencies: [.product(name: "Kadr", package: "kadr")], ...)
]
```

**Dependency direction is one-way:** core has zero knowledge of UI / captions / photos. Each adapter pins a `from: "x.y.z"` floor and tracks core. kadr-captions pins `from: "0.9.2"` (the release that introduced `Caption`); kadr-ui pins `from: "0.11.0"` (after the `FilterID` API hardening). kadr-photos differs further still: it drops tvOS from its `platforms:` list because "Apple doesn't ship Photos.framework on tvOS" — **the companion packages are free to have stricter platform requirements than core**.

The decision rule is captured explicitly in core's DESIGN.md for v0.9.2 captions:

> "The `AVMetadataItem` writer (~100 LOC) is the only piece that genuinely belongs in core — it's the AVFoundation bridge, and AVFoundation is already a core dependency. ... File parsers (~400 LOC across SRT + VTT + iTT, plus their writers) don't earn the core slot."

**Adapter consumers import both:** `import Kadr; import KadrCaptions; let caps = try Caption.load(srt: url); video.captions(caps)`. The parser produces core's `Caption` values; the modifier comes from core. Clean handoff at the value-type boundary.

Each adapter has third-party deps that core forbids itself — KadrUI brings in `swift-snapshot-testing` and `ViewInspector` (test-only) because UI tests need them; core's "no third-party deps" promise survives because adapters opt in for themselves.

## Swift 6 strict-concurrency migration scars (from CHANGELOG)

The v0.11.0 entry is the goldmine — three problems bundled because they "would have been breaking changes to fix post-v1.0":

> **`CancellationToken` race.** Pre-v0.11 the type used `@unchecked Sendable` with **no synchronization** around `_isCancelled` and `exportSession`. `register()` (export background) and `cancel()` (UI) racing produced undefined behavior under Swift 6 strict concurrency. v0.11 backs the `@unchecked Sendable` claim with a real `NSLock` guarding every field access. AVFoundation calls (`cancelExport()`) happen outside the lock to avoid reentrancy with delegate callbacks. **`@unchecked` stays because `AVAssetExportSession` lacks a `Sendable` conformance on macOS** — but it's now load-bearing on the lock invariant, not "trust me".

That's the canonical Swift 6 scar: framework type isn't `Sendable`, you can't fix Apple's headers, you wrap in `@unchecked Sendable` + `NSLock` and document the invariant carefully. Iris will hit identical issues with `AVCaptureSession`, `VNRequest`, `MLModel` instances on macOS.

The v0.11 cycle also surfaced "mutual exclusion at the type level" as a Swift 6 win — flat speed vs curved speed couldn't be expressed as type-level `enum Speed { case flat(Double); case curved(Animation<Double>) }` until they were willing to break the v0.10 API. Same pattern: pick a value type early, accept the breakage now rather than after semver lock.

## Public API style

Result-builder DSL over value types. The consumer's first line:

```swift
let url = try await Video {
    ImageClip(heroImage, duration: 5.0)
}.audio(url: musicURL).export(to: outputURL)
```

`Video { ... }` is the facade. Inside the builder, content types (`VideoClip`, `ImageClip`, `Transition`, `Track`) chain via implicit timeline order; modifiers (`.trimmed`, `.transform`, `.audio`, `.preset`, `.export`) chain off the facade. Everything returns a new value (`-> Video`, `-> VideoClip`) — no mutation. Generic animation via `Animation<Value: Animatable>` parameterized on the property type. Protocol surfaces for extension points: `Compositor`, `MultiInputCompositor`, `TextAnimation`, `Animatable`.

## Architectural patterns to lift into Iris

1. **Companion-package split: separate repos, one-way deps, per-package platform requirements.** Iris's `IrisOverlay`, `IrisDataset`, `IrisTuning` should each be their own Swift package — `iris-overlay`, `iris-dataset`, `iris-tuning` — depending on a core `iris` (which holds `IrisCapture` + `IrisPlayback` + `IrisDetection` + the `Frame` / `Detection` / `Detector` types). The brief currently models them as targets within one package; Kadr proves the multi-repo path. Specific win: `iris-capture` can stay iOS-only (no `.macOS` in platforms) without polluting core. Each can move at its own pace.

2. **`@unchecked Sendable` + `NSLock` for AVFoundation-adjacent types.** Iris will absolutely need this around `AVCaptureSession` and probably `VNRequest`/`MLModel` instances on macOS. Lift the doc-comment shape from `CancellationToken.swift` verbatim: name what the lock guards, document why `@unchecked` is load-bearing on the lock invariant, route framework calls outside the lock to avoid reentrancy. Maps cleanly to whatever Iris's eventual `CaptureSession` wrapper looks like.

3. **Surface-then-engine tier rollout per release.** Every Kadr cycle ships protocol/type surface first ("Tier 0/1 — surface only, engine wires next release"), engine in a follow-up minor. This is what lets `Track {}` exist in v0.6 with `notYetImplemented` paths that lift in v0.7. For Iris this maps to: ship `Detector` protocol + a stub conformer in M2.0, ship Vision-backed detector in M2.1, ship Core ML in M2.2 — same release shape, same forward-compatibility guarantee.

## Patterns to NOT carry over

1. **Result-builder DSL as the primary surface.** Kadr's `Video { ... }` reads beautifully because a video composition IS a declarative tree (clips in order, overlays layered). A CV pipeline isn't — it's a Frame source feeding a Detector feeding an Overlay, configured once and run continuously. Iris's "first line of code" should look more like `let detector = try VisionDetector(model: ...); for await frame in capture.frames { ... }`, not `Pipeline { CameraSource(); VisionDetector(model: ...); BoundingBoxOverlay() }`. Don't force the builder.

2. **Hand-rolled coordinate system in the core API.** Kadr has `Position` (normalized/pixels/percent + 9 named anchors), `Size`, `Anchor`, `Transform` — all custom value types reused across overlays, transforms, animations. That's right for video where every output is a rectangle. Iris should lean on **Vision's normalized coordinate space** + `CGAffineTransform` for rotation/mirroring and centralize the conversion to view space in `IrisOverlay` (as the brief already calls out) — don't invent a parallel coordinate vocabulary.

## Opinions on Iris's still-open questions

Mostly N/A — Kadr is a different domain. Incidental signal: Kadr's `Compositor` protocol is **synchronous** for per-frame work, with the engine wrapping in `applyingCIFiltersWithHandler` for the async boundary. That's evidence for Iris's `Detector` being `async` at the *batch* level (per-Frame call) but with inner pure-Swift work staying sync — and the protocol staying value-shaped (not actor-isolated). Tentatively: question 4 (value vs reference Detector) leans value-type by Kadr's example, since hot-swap models can be a `detector = newDetector` replacement at the call site.

## Verdict

**Borrow from it — structural borrowing only.** The companion-package split, the Swift 6 strict-concurrency invariants on AVFoundation-adjacent types, and the "surface first, engine next release" tier discipline transfer directly. The DSL shape and coordinate vocabulary don't.

## Notes & loose ends

- The companion packages have their own `DESIGN.md` and `ROADMAP.md` files (didn't deep-read). Pattern worth mirroring — each Iris adapter package gets its own design doc, so the boundary stays explicit.
- Kadr-photos is the most instructive precedent for Iris-Dataset: a thin adapter that resolves system-framework values (`PHAsset`) into core value types (`ImageClip`, `VideoClip`). The `PhotosClipResolver+...` file-per-feature split (`+Image`, `+LivePhoto`, `+Album`, `+Metadata`, `+SlowMotion`) is a tidy way to keep a single adapter type from blowing up.
- Kadr core has NO `@MainActor` annotations on public surface. That discipline is what lets the same DSL run inside `@MainActor` SwiftUI bodies AND background export queues. Iris should aspire to the same: core types isolation-agnostic, `@MainActor` only inside `IrisOverlay`/UI-shaped APIs.
- The `nonisolated static func` pattern for pure helpers — exposed for tests + safe to call from any actor — appears throughout both core and adapter packages. Cheap, clear, no actor-isolation drama.
