# Iris

**Shared scaffolding for camera + ML vision apps on Apple platforms.**

Iris is a Swift package that handles the recurring plumbing of a vision app —
camera capture, video playback, ML inference, detection overlays, live tuning,
and dataset capture — so a downstream project can depend on it and focus only on
its specific detection problem. Capture and playback feed the *same* frame
pipeline, detectors are pluggable behind one protocol, and coordinate-space
conversion is handled once, correctly.

> Swift 6.2 · strict concurrency · iOS / iPadOS 26 · macOS 26 · SwiftUI-first ·
> a single SwiftPM library with **no external dependencies**.

> ⚠️ **Very early — work in progress.** This is the beginning of a personal
> project, public mostly so the work is out in the open. The foundations are in
> place and exercised end-to-end by the demo, but the API is unstable, there are
> rough edges, and breaking changes are expected. The genuinely interesting parts
> are still ahead — check back as it grows. No releases or stability guarantees
> yet.

The library boundary is real, though: everything app-specific lives in the demo,
not the package.

---

## What's in the box

Iris ships as **one SwiftPM target** (`Iris`) with one library product. The
folders under `Sources/Iris/` are conceptual responsibilities that share
`Frame`, `Detector`, and coordinate-space conventions — not separate modules.

| Folder        | Platforms     | Role                                                                            |
| ------------- | ------------- | ------------------------------------------------------------------------------- |
| `Capture/`    | iOS only¹     | `AVCaptureSession` actor + `CameraPreview` SwiftUI view → `AsyncStream<Frame>`   |
| `Playback/`   | iOS + macOS   | `PlaybackSource` (AVFoundation-backed) → same `Frame` stream; seek / frame-step / scrubber |
| `Detection/`  | iOS + macOS   | `Detector` protocol + `Detection`; Vision & Core ML adapters; capability model  |
| `Overlay/`    | iOS + macOS   | `DetectionLayer` draws `[Detection]`; `ResultStore` cache; coordinate conversion; raw inspector |
| `Tuning/`     | iOS + macOS   | `@Observable` per-detector settings; capability-derived tuning UI; model catalog |
| `Dataset/`    | iOS + macOS   | Flag frames during playback → headless export as provenance-named PNGs           |
| `Image/`      | iOS + macOS   | One-shot detection on a single still; swap / compare models on one image         |

¹ Capture is `#if os(iOS)`-gated at the file level. `import Iris` still succeeds on
macOS; the capture types are simply not visible. Mac is a model-evaluation and
dataset-curation target — no camera capture.

The cross-cutting types live at the root of `Sources/Iris/`: `Frame` (a
source-agnostic pixel buffer + timestamp + orientation), `Source` (the
`AsyncStream<Frame>` protocol capture and playback both conform to), and the
supporting enums (`SourceState`, `PixelFormat`, …).

## What works today

- **Live capture → detection → overlay** on iOS: point the camera, run a
  detector, see boxes/skeletons drawn in real time.
- **Recorded playback** with the *same* overlay pipeline, on iOS **and** macOS:
  scrub, step frame-by-frame, run inference per frame.
- **Still-image detection**: run detectors on a single photo or a frozen frame
  and A/B compare models on that one image.
- **Pluggable detectors** behind one protocol: built-in **Vision** adapters
  (rectangles, body pose) and **Core ML** models with a pluggable YOLO-style
  `OutputDecoder` (bundled YOLOv12n / YOLO26n, plus file-picked custom models).
- **Honest, capability-derived tuning**: each detector describes what it can do
  (geometry kinds, what its confidence *means*, its tunable knobs), and the
  tuning UI is derived from that — no per-detector UI authoring, no lying about
  a confidence score a detector doesn't really produce.
- **Per-class tuning**: a render-time overlay filter with a global confidence
  floor plus **per-label floors** and **per-label hide/show** — turn `person`
  off entirely while tuning `sports ball` on its own.
- **Raw-data inspector**: see exactly what the detector emitted, unfiltered,
  alongside the filtered overlay.
- **Dataset capture**: flag frames cheaply during playback, then extract them
  headlessly as **provenance-bearing PNGs** whose filenames *are* the dedup
  ledger (no sidecar, no committed annotation format).
- **One unified shell** in the demo: a single shared model (detector +
  confidence) across playback / image / capture, behind one cross-platform
  `NavigationSplitView` sidebar.

## A quick look

A detector is anything that turns a `Frame` into `[Detection]`:

```swift
public protocol Detector: Sendable {
    var availability: DetectorAvailability { get }
    var modelIdentifier: String { get }
    func prewarm() async
    func detect(in frame: Frame) async throws -> [Detection]
}

public struct Detection: Sendable, Hashable, Codable {
    public let boundingBox: CGRect   // normalized [0,1], Vision (lower-left) origin
    public let label: String
    public let confidence: Float     // [0,1]; 1.0 when a detector has no real score
    public let keypoints: [Keypoint]?
    public let skeleton: Skeleton?
    public let mask: Mask?
    public let readout: Readout?     // detector-stamped scalar (e.g. aspect ratio)
    public let sourceModelID: String
}
```

The wiring is uniform regardless of the source: a `Source` (capture or playback)
yields `Frame`s, a `Detector` turns each into `[Detection]`, those land in a
`ResultStore`, and a SwiftUI `DetectionLayer` draws them — applying an
`OverlayFilter` (the global + per-class confidence/visibility filter) at draw
time, while the raw inspector reads the store unfiltered. New backends slot in by
conforming to `Detector`; new sources by conforming to `Source`.

## Requirements

- **Xcode 26+**, Swift **6.2** toolchain.
- **iOS / iPadOS 26+** for the full feature set; **macOS 26+** for playback,
  inference, overlays, and dataset work.
- The package compiles under **Swift 6 language mode with strict concurrency on**
  — that's an invariant, not a setting to relax.

## Using Iris as a dependency

In `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/jgriffin/iris.git", branch: "main")
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "Iris", package: "iris")])
]
```

Iris has no external dependencies of its own.

## The demo app

`Apps/` holds a single SwiftUI shell consumed by two thin targets — **iOS** and
**macOS** — that share all their code in `Apps/Shared/`. It exercises the whole
library: pick a detector, tune it (global + per-class), play a video or load an
image (or, on iOS, run the live camera), and flag frames for a dataset.

The Xcode project is generated by [xcodegen](https://github.com/yonaskolb/XcodeGen)
from `Apps/project.yml`, but the generated `IrisDemo.xcodeproj` **is checked in**,
so you don't need xcodegen unless you're changing project settings.

```bash
# One-time per clone: your signing config (gitignored, one per target).
cp Apps/IrisDemo-iOS/Local.xcconfig.template   Apps/IrisDemo-iOS/Local.xcconfig
cp Apps/IrisDemo-macOS/Local.xcconfig.template Apps/IrisDemo-macOS/Local.xcconfig
#   …then fill in DEVELOPMENT_TEAM (+ a PRODUCT_BUNDLE_IDENTIFIER prefix on iOS).
#   Each target's Shared.xcconfig does `#include? "Local.xcconfig"`.

open Apps/IrisDemo.xcodeproj   # schemes: IrisDemo-iOS, IrisDemo-macOS
```

Run **IrisDemo-iOS** on a physical device for live capture (the simulator has no
camera; playback and image modes work in the simulator). Run **IrisDemo-macOS**
for playback / image / dataset work. To put a test video into the booted
simulator's Documents folder: `just sim-add-video <path>`.

> If you edit `Apps/project.yml`, regenerate with `cd Apps && xcodegen generate`
> (`brew install xcodegen`). Never hand-edit the `.pbxproj`.

## Repository layout

```
Sources/Iris/        the library (Capture, Playback, Detection, Overlay, Tuning, Dataset, Image)
Tests/IrisTests/     Swift Testing suites mirroring Sources/, with real fixtures (Git LFS)
Apps/                the iOS + macOS demo shell (xcodegen-generated project, checked in)
plans/               design intent, milestones, decisions, work log (see below)
explorations/        dated investigations that fed the decisions
tools/               model-export tooling (PyTorch → Core ML)
```

## Development

```bash
swift build          # build the library
swift test           # run the test suites (real .mlpackage + video fixtures via LFS)
```

One-time setup after cloning:

```bash
brew install git-lfs && git lfs install   # fixtures are LFS-tracked
git config core.hooksPath .githooks        # wire the pre-commit format/lint hook
```

- **Formatting & linting:** `.swift-format` + `.swiftlint.yml`, enforced by the
  pre-commit hook and CI.
- **Tests** use real fixtures (sample clips, real `.mlpackage` models) rather
  than mocks wherever tractable. Adding a detector or sink means adding a
  fixture-based test in the same commit.
- **CI** (`.github/workflows/ci.yml`): lint (swift-format + SwiftLint), test
  (library + the iOS demo), and a DocC build.

## Planning & docs

Design intent, the milestone roadmap, settled decisions, and the work log live
under [`plans/`](./plans/):

- [`plans/BRIEF.md`](./plans/BRIEF.md) — the north star: what Iris is and why.
- [`plans/BOARD.md`](./plans/BOARD.md) — where work stands (status tree),
  the milestone roadmap, and the backlog.
- [`plans/DECISIONS.md`](./plans/DECISIONS.md) — settled architectural verdicts.
- [`plans/WORKFLOW.md`](./plans/WORKFLOW.md) — how the planning files work.

[`CLAUDE.md`](./CLAUDE.md) is the constitution: stack, conventions, and the
invariants that constrain how code gets written.

## License

[MIT](./LICENSE) © John Griffin.
