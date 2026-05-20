# search-swift-packages — Search the Swift ecosystem for Iris-relevant packages

parent: [survey-swift-ecosystem](.blockmaster/blocks/260520-survey-swift-ecosystem.md)
created: 2026-05-20 14:00
modified: 2026-05-20 (opened immediately with parent)
context: .blockmaster/blocks/260520-search-swift-packages.md
kind: research
goal: Produce a shortlist of external Swift packages worth deep-reading for Iris, across all six module areas (capture, playback, detection, overlay, tuning, dataset).

### Context

First half of the `survey-swift-ecosystem` arc. Mirrors what `survey-dev-folder` did for `~/dev/`, but pointed at the open ecosystem. The shortlist consumed next by `deep-dive-swift-packages`.

Cast a wide net — the deep-dive step is where we get selective. At this stage, surface anything with signal even if it's a weak match; pruning is cheap, missing a good candidate is expensive.

### Search vectors

**By area** (these are the slots we'd consider adopting/borrowing into):

- **Capture (iOS):** SwiftUI camera preview wrappers, AVCaptureSession SwiftUI bridges, `AsyncStream<CMSampleBuffer>`-style frame producers.
- **Playback (iOS+macOS):** AVPlayer / AVAssetReader frame-extraction packages, scrubber/transport UI, frame-accurate seeking helpers.
- **Detection:** Vision wrappers (especially the new Swift `async` API), CoreML loader/runner packages, YOLO-in-Swift packages, Foundation Models SPM wrappers (iOS 26-era).
- **Overlay:** Bounding-box / keypoint / mask renderers in SwiftUI; coordinate-space helpers (Vision-normalized → view).
- **Tuning:** `@Observable` threshold-control patterns, `MLFeatureProvider`-style live-knob packages.
- **Dataset:** COCO / YOLO / Pascal VOC serialization in Swift, image annotation helpers, dataset-capture pipelines.

**By source** (where to look):

- swiftpackageindex.com — walk tags `vision`, `coreml`, `camera`, `avfoundation`, `video`, `swiftui-camera`, `machine-learning`. Walk "Trending" and "Recently updated" too.
- GitHub topic search — `topic:coreml language:swift`, `topic:vision`, `topic:avfoundation`, `topic:swiftpm + camera/vision/coreml`, `topic:swiftui-camera`.
- Curated lists — awesome-swift, awesome-ios, awesome-coreml, awesome-foundation-models, awesome-avfoundation.
- Apple — DockKit, VisionKit, Vision (new Swift API), Foundation Models. Note official Apple frameworks where they cover Iris's territory.
- Recent web — "best Swift package for X" articles, Swift Forum threads on Foundation Models / new Vision API, recent blog posts (post-WWDC25).

**Filters to apply:**

- iOS 16+ at minimum; iOS 18+ preferred (matches Iris's new-Vision-Swift-API premise).
- Last commit within ~18 months (dormant packages aren't carry-forward candidates).
- Real public API, not "this is just my hobby project that hardcodes my use case."
- Cross-platform claims must be backed by `#if os` discipline (apply the lesson from yolo-ios-app: README aspirational, reality iOS-only).

**Don't re-surface** the 5 already deep-read: `ios-videoCapture`, `PRVisionSpike`, `yolo-ios-app`, `sportvision`, `ActionAndVision`. They're done.

### Output

`explorations/swift-ecosystem/SHORTLIST.md` — table per area, each entry:

```
- **package-name** · github.com/owner/repo · last activity · ★stars · platforms · area · one-line read on relevance to Iris
```

Plus a "dropped" section for candidates that surfaced but didn't make the cut (with a one-line reason each — same shape as `survey-dev-folder`'s "Dropped from shortlist" section).

Target shortlist size: 8–15 packages across all six areas combined. Smaller is fine if the ecosystem is thin in our specific corners.

### Pick-up-here

Dispatch two parallel general-purpose agents — one for structured indices (swiftpackageindex.com tag walks + GitHub topic search), one for curated lists + recent web + Apple. Each writes raw findings to `explorations/swift-ecosystem/raw/<agent>.md`. Synthesize the two into `SHORTLIST.md` once both return. Close the block when shortlist is in place and user has accepted or pruned it.

### Progress

- 2026-05-20 14:00 — created and opened with the parent; two agents dispatched (SPI/GitHub + curated/web/Apple)
- 2026-05-20 — both agents returned; raw findings at `explorations/swift-ecosystem/raw/{structured-indices,curated-web}.md`; synthesized into `explorations/swift-ecosystem/SHORTLIST.md` (7 Tier-1 deep-read candidates, 7 Tier-2 skim, 8 Tier-3 reference, plus Apple-framework verdicts and 7 key reference documents)
- 2026-05-20 — user pruned to 5 Tier-1 (dropped swift-capture-kit + HaishinKit) and skipped Tier-2 entirely. Block closed.

### Outcome

Shortlist for `deep-dive-swift-packages`: [`explorations/swift-ecosystem/SHORTLIST.md`](../../explorations/swift-ecosystem/SHORTLIST.md). Five packages for deep-read:

1. **Apple AVCam (SwiftUI sample)** — canonical `CaptureService` actor architecture
2. **NextLevel** (2,306★, Swift 6) — battle-tested AVCapture wrapper, real Swift 6 migration scars
3. **MijickCamera** (622★, SwiftUI-first) — only SwiftUI camera with zero data-races
4. **Kadr** (41★, Swift 6.0) — architectural template (multi-target SPM with companion adapter packages, different domain)
5. **PrivateFoundationModels** (4★) — only example treating FM/CoreML/MLX as interchangeable backends; informs M1 Q6

**Eight headline findings** worth surfacing now (full discussion in SHORTLIST.md):

1. `IrisOverlay`, `IrisTuning`, `IrisDataset` have **no SwiftPM competition** at all — Iris is the only player in those three slots by ecosystem necessity.
2. Apple has eaten the Detection-wrapper space with the iOS 18 Vision Swift API rewrite; community wrappers are nearly gone.
3. `AsyncStream<CMSampleBuffer>` per-frame is consensus but unpackaged — `IrisCapture`'s contribution is packaging, not architecture.
4. Capture is the most contested slot (three live competitors) but none is a perfect fit.
5. macOS camera packages don't exist beyond HaishinKit — validates "no macOS capture" decision.
6. Foundation Models wrappers are immature but moving fast; no VLM captioning package yet — M6 is feasible *and* novel.
7. **Create ML JSON should be added to Q3** sidecar-format options alongside COCO and YOLO.
8. **"Detector" is search-ambiguous in SPM-land** (means QR/charset/jailbreak detection) — anchor in module docs.

Apple-framework verdicts: depend directly on Vision (new Swift API), CoreML, AVFoundation, Foundation Models (M6); ignore VisionKit/DockKit for v1; reconsider Create ML JSON for `IrisDataset`.

Key reference docs (not packages): Apple AVCam sample page, Swift Forums Dec-2025 thread on AVCaptureSession + Swift 6, WWDC24 #10163 (Vision Swift API rewrite), WWDC25 #286/#301/#259 (Foundation Models), machinethink.net "How to display Vision bounding boxes."
