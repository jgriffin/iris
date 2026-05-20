# Swift ecosystem shortlist for Iris

**Date:** 2026-05-20
**Source:** synthesis of [`raw/structured-indices.md`](./raw/structured-indices.md) (SwiftPackageIndex + GitHub topic search) and [`raw/curated-web.md`](./raw/curated-web.md) (awesome-* lists + recent web + Apple frameworks).

This is the shortlist for `deep-dive-swift-packages` to read against. Tiers reflect how much time the deep-dive should spend — Tier 1 gets a full four-lens read like `review-prior-projects` did; Tier 2 gets a README + `Package.swift` + headline-API skim; Tier 3 is referenced for one specific thing without a sit-down read.

---

## Headline findings (skip if you've read both raw files)

1. **Three Iris modules have no ecosystem competition at all.** Both agents independently confirmed: there is **no Swift package** for (a) drawing `[Detection]` over a video frame with proper coord-space conversion (`IrisOverlay`'s niche), (b) `@Observable`-bound threshold/filter tuning over a generic detector (`IrisTuning`'s niche), or (c) COCO/YOLO sidecar emission from device captures (`IrisDataset`'s niche). Iris will be the only player in these three slots — by ecosystem necessity, not by design choice.

2. **Apple has eaten the "Detection wrapper" space.** The iOS 18 Vision Swift API rewrite (`async/await`, Swift 6, Sendable, dropped `VN` prefix) made most community wrappers obsolete. The community detection layer has nearly emptied out — SwiftOCRKit and a handful of dormant projects are what's left. `IrisDetection` is largely a *composition* problem (Vision + CoreML + Foundation Models behind one protocol), not a "fill what Apple is missing" problem.

3. **`AsyncStream<CMSampleBuffer>` per-frame is consensus but unpackaged.** The Swift Forums thread (Dec 2025) converges cleanly on the actor + private-delegate + `AsyncStream<T>` pattern. NextLevel adopts it for *session events*. Nobody has packaged the per-frame `AsyncStream<Frame>` flavor specifically. **`IrisCapture`'s contribution is the packaging, not the architecture.**

4. **Capture is the most contested slot — three live competitors, none a perfect fit.** NextLevel (2.3k★, Swift 6, UIKit-shaped), MijickCamera (622★, SwiftUI-first but opinionated app-shell), swift-capture-kit (4★, brand new, partial overlap). Apple's AVCam sample (post-WWDC24) is the canonical reference everyone implicitly converges on.

5. **macOS camera packages essentially don't exist beyond HaishinKit.** Validates Iris's "no macOS camera capture" decision — the ecosystem hasn't solved this and the prevailing pattern is iOS-only.

6. **Foundation Models community wrappers are immature but moving fast.** 3 notable packages in ~9 months since GA. No Vision-language captioning package exists yet wrapping FM's multimodal — M6 is feasible *and* novel.

7. **Create ML JSON should be added to the Q3 sidecar-format decision.** It's the iOS-native, Apple-blessed annotation format that round-trips into Apple's own training tool. Surface this when `IrisDataset` plans land.

8. **"Detector" is a search-ambiguous name in SPM-land.** It means QR/charset/jailbreak/leak detection. Iris's `Detector` protocol will be unique-enough by import context but won't be findable by search. Worth noting in module docs.

---

## Decisions (2026-05-20)

- **Tier 1 pruned to 5** — dropped `swift-capture-kit` (too new + 4★, low signal) and `HaishinKit` (streaming-shaped, lower priority). The 5 that proceed: **Apple AVCam, NextLevel, MijickCamera, Kadr, PrivateFoundationModels**.
- **Tier 2 skipped entirely.** Headline findings already cover what the skim would surface; revisit individually only if a specific question comes up during M1 planning.
- **Tier 3 stays as reference.** No reads planned.

## Tier 1 — full four-lens deep read

These are the packages the `deep-dive-swift-packages` block should read with the same depth as `review-prior-projects` used: capture entrypoint / Frame plumbing / detection async / overlay coords + public-API-shape lens. Per-package note under `explorations/swift-ecosystem/<slug>.md`.

| Package | URL | ★ | Last commit | Platforms | Why Tier 1 |
| --- | --- | --- | --- | --- | --- |
| **Apple AVCam (SwiftUI)** | [developer.apple.com/docs/avfoundation/avcam](https://developer.apple.com/documentation/avfoundation/avcam-building-a-camera-app) | n/a | post-WWDC24 | iOS 18+ | **Canonical reference** for `IrisCapture` architecture: `CaptureService` actor + SwiftUI shell + `AsyncStream` results + `nonisolated let` session. Swift Forums consensus thread converges on the same shape. Read for the architecture before writing any Iris code. |
| **NextLevel** | [github.com/NextLevel/NextLevel](https://github.com/NextLevel/NextLevel) | 2,306 | 2026-02 | iOS 15+ / 16+ modern | The most battle-tested AVCaptureSession wrapper that's actually shipped Swift 6 migration. Read the CHANGELOG for the real gotchas: AudioChannelLayout crash, sample-buffer Sendable issues, interruption handling. **API is UIKit-shaped** (singleton + delegates + `renderToCustomContextWithImageBuffer` per-frame hook) — read for what to *learn from*, not depend on. |
| **MijickCamera** | [github.com/Mijick/Camera](https://github.com/Mijick/Camera) | 622 | 2025-09 | iOS 14+ | The only SwiftUI-first camera package with Swift 6 support and zero data-race errors on SPI. **Opinionated full-app shell** (built-in controls, gestures, capture review screen) — Iris needs the bottom half (session + preview + frame stream) without the top half. Read to see how a SwiftUI camera *can* be written, then deliberately do less. |
| **Kadr** | [github.com/SteliyanH/kadr](https://github.com/SteliyanH/kadr) | 41 | 2026-05-19 | iOS 16+/macOS 13+/tvOS/visionOS, Swift 6.0 | **Architectural template.** Different domain (declarative video composition) but the codebase shape Iris is aiming for: Swift 6 strict concurrency, async/await throughout, zero data-race errors, multi-target with `kadr-ui` / `kadr-captions` / `kadr-photos` companion packages — almost 1:1 mirror of Iris's planned `IrisOverlay` / `IrisDataset` adapter pattern. Read the README, ARCHITECTURE doc, and v0.10–v0.12 changelogs for real Swift 6 migration pain. |
| **PrivateFoundationModels** | [github.com/john-rocky/PrivateFoundationModels](https://github.com/john-rocky/PrivateFoundationModels) | 4 | 2026-05-14 | iOS 18+ | "Same call site, native passthrough on iOS 26 (Apple Intelligence), CoreML / MLX backends on older OSes. Drop-in source compatible." **Directly informs M1 open question #6** (Foundation Models as Detector backend vs separate Captioner). Only example of treating FM/CoreML/MLX as interchangeable inference backends — exactly the polymorphic-backend pattern Iris is contemplating. Tiny audience, big design relevance. |
| **swift-capture-kit** | [github.com/atelier-socle/swift-capture-kit](https://github.com/atelier-socle/swift-capture-kit) | 4 | 2026-05-16 | iOS/macOS/visionOS, Swift 6.2 | **Existential-threat candidate.** Brand new (v0.1.2, 4 days old). Self-describes as "Unified media capture, encoding & streaming for Apple platforms." Scope partially overlaps `IrisCapture`. Read for: how they handle cross-platform `#if os` divergence, what their Sendable boundaries look like at the session/encoder/stream seam, what their public API actually is. Inform Iris's positioning. |
| **HaishinKit** | [github.com/HaishinKit/HaishinKit.swift](https://github.com/HaishinKit/HaishinKit.swift) | 3,043 | 2026-05 | iOS/macOS/tvOS/visionOS, Swift 6 | **The only mainstream Swift package with serious cross-platform AVCaptureSession support.** Streaming purpose (RTMP/SRT) is outside Iris scope, but the cross-platform capture plumbing is unique — if Iris ever revisits "what would a macOS capture target look like?", this is the reference. Read at lower priority than the iOS-focused ones; the Swift 6 + macOS + capture combination is exclusive to this project. |

---

## Tier 2 — README + Package.swift + headline-API skim

Don't write per-package notes. Open the README, scan `Package.swift`, note the public API shape and any patterns worth folding into `RECOMMENDATIONS.md`. ~20 min each.

| Package | URL | ★ | Skim for |
| --- | --- | --- | --- |
| **Pillarbox** | [github.com/SRGSSR/pillarbox-apple](https://github.com/SRGSSR/pillarbox-apple) | 103 | Production-grade cross-platform `AVPlayer` stack. Read for how a serious multi-platform Apple media library structures itself (DocC, tests, module graph). Not for frame-streaming — it's broadcast-shaped. |
| **AsyncGraphics** | [github.com/heestand-xyz/AsyncGraphics](https://github.com/heestand-xyz/AsyncGraphics) | 417 | "Edit images and video with Swift concurrency, powered by Metal." Possible adoption candidate inside `IrisOverlay` for GPU-accelerated overlay rendering. Decide skim-only whether worth the dep weight. |
| **SemanticImage** | [github.com/john-rocky/SemanticImage](https://github.com/john-rocky/SemanticImage) | 157 | Wraps Vision + CoreML for segmentation/face/object detection/depth. Closer to a utility kit than a `Detector` protocol. Skim for "what does john-rocky reach for" since he's also the PrivateFoundationModels author. |
| **SwiftTasksVision** | [github.com/paescebu/SwiftTasksVision](https://github.com/paescebu/SwiftTasksVision) | 30 | SPM wrapper around Google MediaPipe Tasks. Skim for "what does a non-Vision/non-CoreML Detector backend look like?" Reference for the alternate-backend question. |
| **SwiftOCRKit** | [github.com/DrcKarim/SwiftOCRKit](https://github.com/DrcKarim/SwiftOCRKit) | 21 | Thin async wrapper around pre-iOS-18 Vision OCR. Skim the *shape* of the wrapper (clean `async let text = ...`); ignore the implementation (the new Vision API supersedes it). |
| **FoundationModelsTools** | [github.com/rudrankriyam/FoundationModelsTools](https://github.com/rudrankriyam/FoundationModelsTools) | 135 | Pre-built `Tool` adapters for Apple Foundation Models. Skim for the Tool-adapter public-API shape — informs how an Iris `FoundationModelsDetector` should expose configurability. |
| **OpenFoundationModels** | [github.com/1amageek/OpenFoundationModels](https://github.com/1amageek/OpenFoundationModels) | 56 | 100% API-compatible FoundationModels implementation backed by Claude/OpenAI/Ollama/MLX. **Interesting as a CI/test surface** — run Iris's Captioner without Apple Intelligence hardware. Skim to confirm the API compatibility claim. |

---

## Tier 3 — reference only

Don't read; just know they exist. Cite from `RECOMMENDATIONS.md` if relevant.

- **Foundation-Models-Framework-Example** (rudrankriyam, 1.0k★) — sample app, not a library. Keep on hand for the M6 spike.
- **VideoTrimmerControl** (UIKit) — UX reference for trim/scrub UI.
- **swiftui-loop-videoplayer** (98★) — looping `AVPlayer` SwiftUI wrapper; no frame-level access.
- **mlx-swift-vision** (3★) — only SPM attempt to bring MLX into a vision pipeline. Reference for "what if MLX becomes a third backend."
- **Aespa** (136★, dormant) — once-popular SwiftUI camera, now stale. Reference for "see, no maintained SwiftUI camera package."
- **fatihdurmaz/yolo-ios-sdk** (17★, dormant) — confirms no live SPM-distributed YOLO/Detector library beyond Ultralytics' demo app.
- **NextLevelSessionExporter** (276★) — capture-side export/transcode; out of Iris scope.
- **SwiftAprilTag** (0★, 11 days) — fiducial detection; useful niche reference.

---

## Apple official frameworks — depend, wrap, or ignore

| Framework | iOS / macOS floor | Verdict | Notes |
| --- | --- | --- | --- |
| **Vision** (new Swift API) | iOS 18+ / macOS 15+ | **Depend directly.** | Canonical `Detector` backend. Iris's `Detector` protocol should compose `*Request` types as one backend. WWDC24 #10163 is the reference session. |
| **CoreML** | iOS 11+ | **Depend directly.** | Model-loading substrate. Apple-generated Swift interface is idiomatic; community wrappers are obsolete. `IrisDetection` will have a `CoreMLDetector` adapter. |
| **Foundation Models** | iOS 26+ / macOS 26+ | **Depend directly (M6).** | On-device LLM + multimodal vision encoder. Powers M6 captioning and possibly a `Detector` backend for VLM-style detection. WWDC25 #286, #301, #259 are the sessions. |
| **AVFoundation / AVKit** | universal | **Depend directly.** | Foundational; no avoiding. Apple AVCam sample is the architectural reference. |
| **VisionKit** | iOS 13/16/17+ | **Mostly ignore for v1; revisit subject lifting at M6.** | DataScannerViewController is the *opposite* of Iris (closed turnkey UI vs composable pipeline). ImageAnalysisOverlayView is macOS-static-image. |
| **DockKit** | iOS 17+ | **Ignore for v1; document as downstream-app recipe.** | Iris produces detections; DockKit consumes them to drive motorized stands. Make sure `Detection` shape is consumable without translation. |
| **Create ML / Create ML Components** | macOS / iOS 15+ | **Ignore as dep, but Create ML JSON is the sleeper for `IrisDataset`.** | Iris should weigh Create ML JSON as a third sidecar format option alongside COCO and YOLO in Q3 — lowest friction on Apple hardware. |

---

## Key references (read these documents, not code)

Pin these for the deep-dive and for M1 planning:

- **Apple AVCam SwiftUI sample** — [developer.apple.com/documentation/avfoundation/avcam-building-a-camera-app](https://developer.apple.com/documentation/avfoundation/avcam-building-a-camera-app). The de-facto `CaptureService` architecture.
- **Swift Forums — "Safely use AVCaptureSession Swift 6.2 concurrency"** (Dec 2025) — [forums.swift.org/t/safely-use-avcapturesession-swift-6-2-concurrency/83622](https://forums.swift.org/t/safely-use-avcapturesession-swift-6-2-concurrency/83622). Community consensus on actor + AsyncStream pattern.
- **WWDC24 #10163 — "Discover Swift enhancements in the Vision framework"** — the rewrite that justifies Iris's iOS 18+/26 floor.
- **WWDC24 #10164 — "What's new in DockKit"** — for the downstream integration recipe.
- **WWDC25 #286 — "Meet the Foundation Models framework"** + **#301 (deep dive)** + **#259 (code-along)** — for M6.
- **WWDC25 #272 — "Read documents using the Vision framework"** — `RecognizeDocumentsRequest` is iOS 26-new.
- **machinethink.net — "How to display Vision bounding boxes"** — canonical coordinate-space transformation math for `IrisOverlay`.

---

## Updates to fold back into `explorations/prior-projects/RECOMMENDATIONS.md`

Land these when `deep-dive-swift-packages` closes (don't apply now — wait for the deep-read to confirm):

1. **Architectural reference: Apple AVCam.** Pin as the de-facto `IrisCapture` blueprint, with the Swift Forums Dec-2025 thread as the public-discussion record.
2. **Q3 sidecar format choice expands from {COCO, YOLO, Pascal VOC} to include Create ML JSON.** Apple-blessed, round-trips into Create ML, iOS-native.
3. **Naming guidance: `Detector` is search-ambiguous in SPM-land** (means QR / charset / jailbreak / leak detection there). Module docs should anchor it as "vision/object detector" explicitly.
4. **Ecosystem-gap reframing.** Move the "Iris is filling these gaps" claim from intuition to ecosystem evidence: no SwiftPM package exists for detection-overlay coord conversion, threshold tuning over a Detector, or COCO/YOLO sidecar capture.
5. **Cross-platform validation.** Iris's "no macOS camera capture" decision is validated by HaishinKit being the only Swift package with serious cross-platform `AVCaptureSession` support, *and* it's a streaming stack (not a capture primitive). The ecosystem hasn't solved this.

---

## Considered but dropped

The full per-source dropped lists live in [`raw/structured-indices.md`](./raw/structured-indices.md) and [`raw/curated-web.md`](./raw/curated-web.md). Headline reasons across the ~30 dropped candidates:

- **Dormant** (1+ years inactive): Aespa, CameraManager, CameraView, Camera-SwiftUI, SwiftyCam, CameraKit-iOS, Mentalist, MNISTKit, VisionFaceAware, Evil, kubrick, BroadcastWriter, AVFoundationCombine.
- **Wrong modality**: FluidAudio, Qwen3Speech, Wax, swift-embeddings, MochiDiffusion, olleh, TranscriptDebugMenu, swift-context-management, executorch, ggml.
- **Wrong job**: NextLevelSessionExporter (export, not capture), GPUImage 3 / Harbeth (filter pipelines), ARVideoKit (ARKit), Player (UIKit AVPlayer wrapper), HLSVideoCache / VideoIO / SwiftFFmpeg (codec/transport).
- **Commercial / SDK-flavored**: Roboflow Swift SDK, LiveKit, StreamVideo, VideoEditorSDK.
- **Adjacent but not overlapping**: PermissionsKit (orthogonal), coremltools / SwiftCoreMLTools (model production, not consumption), Create ML (consume its output, not its API), MediaPicker / Fusuma / YPImagePicker (photo pickers, not capture).

---

## Sources

- [`raw/structured-indices.md`](./raw/structured-indices.md) — full SwiftPackageIndex tag walk + GitHub topic search audit trail.
- [`raw/curated-web.md`](./raw/curated-web.md) — full awesome-* list walk + web search + WWDC session references + Apple frameworks pass.
