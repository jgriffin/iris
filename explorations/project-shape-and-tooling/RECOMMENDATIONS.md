# Project shape & tooling — recommendations

> **Status: CONFIRMED 2026-05-20.** Verdicts walked through interactively and
> confirmed across two passes. M1 setup proceeds from these.

Decisions for how the Iris Swift package is shaped, where its test/demo apps
live, what tooling guards quality, and how test fixtures are managed. Final
exploration of M0; output drives M0 close and M1 (capture-core) setup.

**Methodology.** Interactive Q&A walkthrough between user and Claude, four
headline questions landed sequentially. Not researcher-dispatched — sibling
M0 explorations (`prior-projects`, `swift-ecosystem`, `dev-folder-survey`,
`runtime-pipeline-architecture`, `display-pipeline-architecture`) covered
the deeper engineering surfaces; this block resolves the operational ones.

## TL;DR

| Topic | Verdict |
|---|---|
| **Package shape** | One package, one product, one `Iris` target. Components organized as folders under `Sources/Iris/`. Capture sources gated `#if os(iOS)` at file level. `Tuning` and `Dataset` folders deferred to M4 / M5 — not scaffolded now. |
| **Test/demo apps** | `Apps/IrisDemo-iOS.xcodeproj` + `Apps/IrisDemo-macOS.xcodeproj`. Real Xcode projects, local-path SwiftPM dependency on Iris. |
| **Tooling chain** | swift-format + SwiftLint + GitHub Actions CI + DocC + pre-commit (native git hook in `.githooks/`, fast checks only — no tests in hook). |
| **Fixtures** | Git LFS from day one. Fixtures in `Tests/IrisTests/Fixtures/`, tracked via `.gitattributes`. |

---

## 1. Package shape

**Verdict.** Single SwiftPM package, single target, single umbrella product.
Components organized as folders under `Sources/Iris/`:

```
iris/
  Package.swift                  # one target, one product
  Sources/Iris/
    Frame.swift                  # shared core types at root
    Detector.swift
    Detection.swift
    Capture/                     # iOS-only, file-level #if os(iOS)
      CameraPreview.swift
      CameraSession.swift
    Playback/
      AssetReader.swift
      Scrubber.swift
    Detection/
      VisionDetector.swift
      CoreMLDetector.swift
    Overlay/
      DetectionOverlay.swift
      CoordinateSpace.swift
  Tests/IrisTests/
    Fixtures/                    # LFS-tracked
    Capture/
    Playback/
    Detection/
    Overlay/
  Apps/IrisDemo-iOS.xcodeproj/
  Apps/IrisDemo-macOS.xcodeproj/
```

**Package.swift sketch:**

```swift
let package = Package(
    name: "Iris",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "Iris", targets: ["Iris"])],
    targets: [
        .target(name: "Iris"),
        .testTarget(
            name: "IrisTests",
            dependencies: ["Iris"],
            resources: [.process("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
```

**Rationale.** Multi-target structure buys enforced module boundaries — real
value when boundaries can't be trusted, low value for a small solo-dev
library where modules genuinely co-evolve through M1–M3. The original "six
modules, each a SwiftPM target" framing also hid a structural problem: per
BRIEF, `Frame` is source-agnostic — but no module owned `Frame` without
forcing backwards dependencies (Playback depending on Capture) or
introducing an unmentioned seventh `IrisCore` target. A single target
sidesteps this entirely; `Frame` lives at `Sources/Iris/Frame.swift` and
all components reference it freely.

Folder organization plus disciplined imports gives ~80% of the
enforced-boundary benefit at ~10% of the ceremony cost. Splitting into
separate targets later (if module boundary pain surfaces at M2 or M3) is a
non-breaking change — roughly a half-day per module extracted (move files,
declare cross-target deps, lift `internal` → `public` where API needs to
cross the new boundary).

**iOS-only Capture, file-level gating.** Capture source files wrap their
contents in `#if os(iOS)`:

```swift
// Sources/Iris/Capture/CameraSession.swift
#if os(iOS)
import AVFoundation
// ... entire file ...
#endif
```

One `#if` per file, not per function. On macOS, `import Iris` succeeds and
Capture types are not visible in the namespace. Whole-subsystem platform
gating is the right tool here (the CLAUDE.md working-norms note covers the
"don't fork an individual type's API across platforms" distinction).

**Tuning and Dataset deferred to M4 / M5.** Both are hard to design well
before seeing real detector output (Tuning) or real capture flows
(Dataset). They're not scaffolded at M1 — folders appear in their
respective milestones when the work begins. At that point, decide whether
they stay as folders within Iris or graduate to separate targets. Dataset
is the more likely candidate for separation given its IO concerns and
possible heavier dependencies.

**Downstream actions:**
- Write `Package.swift` with a single `Iris` target and library product.
- Declare `platforms: [.iOS(.v26), .macOS(.v26)]`.
- Enable Swift 6 language mode and strict concurrency.
- Scaffold `Sources/Iris/` with `Capture/`, `Playback/`, `Detection/`,
  `Overlay/` folders and shared root files (`Frame.swift`,
  `Detector.swift`, `Detection.swift`).

**Follow-ups / risks:**
- Verify Swift 6 strict concurrency compiles cleanly across folder
  boundaries within a single target. Likely fine; untested.
- If module-boundary pain surfaces at M2/M3, extract folders to separate
  targets as needed. Migration is mechanical.

---

## 2. Test/demo apps

**Verdict.** Two real Xcode projects under `Apps/`:

```
iris/
  Package.swift
  Sources/Iris/
  Tests/IrisTests/
  Apps/
    IrisDemo-iOS.xcodeproj/
    IrisDemo-iOS/
      Info.plist             # NSCameraUsageDescription, etc.
      IrisDemoApp.swift      # @main SwiftUI app
      ContentView.swift
    IrisDemo-macOS.xcodeproj/
    IrisDemo-macOS/
      IrisDemoApp.swift
      ContentView.swift
```

Each project depends on Iris via a local-path SwiftPM reference (Xcode →
File → Add Package Dependencies → Local…, pointing at the repo root). No
external fetch.

**Rationale.** Camera capture testing on iOS needs full Info.plist control —
`NSCameraUsageDescription` is mandatory, and `AVCaptureSession` refuses to
start without it. SwiftPM `.executableTarget` can build iOS apps but
Info.plist permission strings, app icons, and provisioning need awkward
workarounds. A real `.xcodeproj` sidesteps all of it.

The macOS demo doesn't *need* the Xcode-project workflow (no camera
prompts), but keeping both as full projects keeps the mental model
symmetric.

**Downstream actions:**
- Create `Apps/IrisDemo-iOS.xcodeproj` at M1 (when capture goes live).
- Create `Apps/IrisDemo-macOS.xcodeproj` at M3 (when playback hits macOS).
- Add `xcuserdata/`, `*.xcworkspace/xcuserdata/` to `.gitignore`.
- Document the local-path-SwiftPM wiring in README once first app exists.

**Follow-ups / risks:**
- `.xcodeproj` files in git churn on project-level setting changes. Be
  disciplined about not committing scheme/user-state diffs.
- If we later want fully scriptable project regeneration (Tuist, xcodegen),
  revisit then. Adding it later is cheap.

---

## 3. Tooling chain

**Verdict.** Five tools, wired at M1 setup:

| Tool | Role | Config file |
|---|---|---|
| **swift-format** | Autoformatter (official Apple) | `.swift-format` |
| **SwiftLint** | Style + correctness linter | `.swiftlint.yml` |
| **GitHub Actions** | CI on macOS-latest, Xcode 16+, Swift 6 | `.github/workflows/ci.yml` |
| **DocC** | API docs from `///` + docc catalog | `Sources/Iris/Iris.docc/` |
| **Pre-commit** | Native git hook (no Python framework) | `.githooks/pre-commit` |

**Pre-commit hook flavor: native shell script, not the Python framework.**
Lower setup friction (one-time `git config core.hooksPath .githooks` per
clone) and no language runtime to manage. Runs `swift-format` on staged
`.swift` files and optionally a light SwiftLint check. **Tests do NOT run
in the hook** — they live in CI. Commit-time hooks stay sub-second.

**CI pipeline shape (sketch):**

```yaml
# .github/workflows/ci.yml
name: CI
on: [push, pull_request]
jobs:
  lint:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
        with:
          lfs: true
      - run: swift-format lint --strict --recursive Sources Tests
      - run: swiftlint --strict

  test:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
        with:
          lfs: true
      - run: swift test
      - run: xcodebuild test
          -project Apps/IrisDemo-iOS.xcodeproj
          -scheme IrisDemo-iOS
          -destination 'platform=iOS Simulator,name=iPhone 16'
      - run: xcodebuild build
          -project Apps/IrisDemo-macOS.xcodeproj
          -scheme IrisDemo-macOS

  docs:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - run: xcodebuild docbuild -scheme Iris -derivedDataPath build
```

**Rationale.** Iris is a library other projects will depend on, which tilts
judgement toward higher tooling investment than a one-shot app would
warrant:

- DocC is non-negotiable — consumers need to read docs without cloning.
- SwiftLint catches things `swift-format` doesn't (cyclomatic complexity,
  force-unwraps, etc.).
- A pre-commit hook catches formatting drift in seconds; CI catches
  cross-platform regressions in minutes. The two feedback-loop scales
  complement each other.
- Swift 6 strict concurrency catches many correctness issues already, but
  SwiftLint still adds signal on style and anti-patterns.

**For agentic work.** The pre-commit hook also fail-fasts on formatter
drift when Claude (or any AI assistant) edits files — keeps the agent
honest without burning context arguing with the linter.

**Downstream actions:**
- Add `.swift-format` (Apple's default as starting point).
- Add `.swiftlint.yml` with a tight ruleset — opt in to `force_unwrapping`,
  etc.; opt out of style rules that conflict with swift-format.
- Add `.github/workflows/ci.yml` matching the sketch.
- Add `.githooks/pre-commit` shell script running swift-format on staged
  files; document `git config core.hooksPath .githooks` in README.
- Initialize a DocC catalog at `Sources/Iris/Iris.docc/`.
- Pin tool versions in CI to avoid surprise upgrades.

**Deferred (revisit if signal warrants):**
- Codecov coverage uploads.
- xcbeautify for prettier CI logs.
- periphery for dead-code detection (wait until public API stabilizes).

---

## 4. Fixture story

**Verdict.** Git LFS from day one. Fixtures live in
`Tests/IrisTests/Fixtures/` and are tracked by Git LFS via `.gitattributes`.

```
# .gitattributes
Tests/IrisTests/Fixtures/*.mov            filter=lfs diff=lfs merge=lfs -text
Tests/IrisTests/Fixtures/*.mp4            filter=lfs diff=lfs merge=lfs -text
Tests/IrisTests/Fixtures/*.mlmodel        filter=lfs diff=lfs merge=lfs -text
Tests/IrisTests/Fixtures/*.mlpackage/**   filter=lfs diff=lfs merge=lfs -text
Tests/IrisTests/Fixtures/*.png            filter=lfs diff=lfs merge=lfs -text
```

`.gitignore` still excludes top-level `*.mov`, `*.mp4`, `captures/`,
`datasets/`, `*.mlmodelc/` — the LFS-tracked Tests paths are explicit in
`.gitattributes` so they survive the broader ignore.

**Per-contributor setup:**

```bash
brew install git-lfs
git lfs install
# clone/pull as normal — LFS files materialize automatically
```

**CI:**

```yaml
- uses: actions/checkout@v4
  with:
    lfs: true
```

**Rationale.** Two factors pushed past the simpler "small fixtures
committed" option:

1. **Detection fixtures grow.** Even a small Core ML model can be 5–50MB.
   M6 adds custom models and Foundation Models adapters — fixture weight is
   likely to climb.
2. **Future-proofing is cheap.** LFS adds one `brew install` per
   contributor and one CI checkout flag. Migrating "commit small, switch to
   LFS later" requires rewriting git history.

**Downstream actions:**
- Run `git lfs install` at repo init.
- Add `.gitattributes` declaring tracked extensions under
  `Tests/IrisTests/Fixtures/`.
- Update CI workflow to use `lfs: true` in checkout.
- Document contributor setup in README before merging the first fixture.

**Follow-ups / risks:**
- GitHub LFS storage is free up to 1GB; bandwidth free up to 1GB/month.
  Beyond that, $5/month per 50GB data pack. Monitor usage as fixtures grow.
- LFS bandwidth burns on every CI run unless cached. Add GitHub Actions
  cache for `~/.cache/git-lfs` if CI runs frequently.
- If Iris ever releases as a binary `.xcframework`, LFS-tracked fixtures
  must not be included in the package artifact.

---

## Next steps (M0 → M1)

With these four verdicts in hand, M0's `project-shape-and-tooling` block is
ready to close. M0 itself then has all five exploration children closed.

Suggested sequencing:

1. **BRIEF.md / CLAUDE.md refresh — done.** Both files updated in the same
   pass as these verdicts: the "six modules, each a SwiftPM target" framing
   in CLAUDE.md is replaced; BRIEF gets a structural paragraph in
   "High-level components" pointing at this doc.
2. **Close `project-shape-and-tooling` block.**
3. **Close M0.**
4. **Pull M1 (capture-core).** Scaffold:
   - `Package.swift` with single `Iris` target + library product
   - `.gitignore` + `.gitattributes` (LFS)
   - `.swift-format`, `.swiftlint.yml`, `.githooks/pre-commit`
   - `.github/workflows/ci.yml`
   - `Apps/IrisDemo-iOS.xcodeproj` (real Xcode project, NSCameraUsageDescription wired)
   - `Sources/Iris/` skeleton with `Frame.swift`, `Detector.swift`,
     `Detection.swift` at root and a starter `Capture/` folder
     (`CameraPreview.swift`, `CameraSession.swift`)
   - `Tests/IrisTests/Fixtures/` with first LFS-tracked fixture

M1 scaffolding is roughly a half-day if the tooling configs land right on
first try.
