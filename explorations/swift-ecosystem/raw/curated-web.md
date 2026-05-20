# Curated + web + Apple-frameworks scan

**Date:** 2026-05-20
**Scope:** awesome-* lists, recent web articles, Swift Forum threads, WWDC25 sessions, and Apple's own in-OS frameworks. Companion scout covered Swift Package Index + GitHub topic search.

**Sources walked:**
- https://github.com/matteocrippa/awesome-swift (alive, last updated 2026-05-05)
- https://github.com/vsouza/awesome-ios (alive)
- https://github.com/likedan/Awesome-CoreML-Models (alive, last commit Jun 2025; 7k stars)
- https://github.com/SwiftBrain/awesome-CoreML-models (mostly model directory; older)
- https://github.com/mgt-la/awesome-core-ml (older curated list)
- https://github.com/onmyway133/awesome-machine-learning (older, mostly conversion tools / pre-iOS-18)
- https://github.com/tomkrikorian/awesome-visionOS (visionOS-focused; not Vision-framework focused)
- https://github.com/stevenpaulhoward/awesome-visionos (visionOS; same)
- https://github.com/topics/coreml?l=swift, https://github.com/topics/vision-framework?l=swift
- https://forums.swift.org/t/safely-use-avcapturesession-swift-6-2-concurrency/83622 (key Swift Forums thread, Dec 2025)
- https://forums.swift.org/t/avcapturesession-and-concurrency/72681
- https://developer.apple.com/wwdc25/ session pages (272 Vision documents, 286 Foundation Models, 301 deep-dive, 259 code-along, 248 prompt safety)
- https://developer.apple.com/videos/play/wwdc2024/10163/ (Vision Swift API, the post-iOS-18 modernization)
- https://developer.apple.com/videos/play/wwdc2024/10164/ (DockKit intelligent tracking)
- https://developer.apple.com/documentation/avfoundation/avcam-building-a-camera-app (Apple's reference SwiftUI camera sample)
- createwithswift.com, donnywals.com, avanderlee.com (SwiftLee), swiftbysundell.com, hackingwithswift.com — checked for camera/vision/Foundation Models posts within last 18 months

**Note:** there is no dedicated `awesome-vision` (Apple Vision-framework) list. The visionOS lists are about the Vision Pro headset, not the Vision framework. This is itself a finding — the Vision/CoreML/Camera tooling community lives on the Swift Package Index, GitHub topic search, and a handful of individual blogs, not in a single curated list.

---

## Candidates worth deep-reading

### Capture (iOS)

- **NextLevel** — https://github.com/NextLevel/NextLevel · 2.3k ★ · iOS 15+ (16+ for modern API) · "Media capture camera library; Swift 6, async/await, AsyncStream of session events" · The closest mainstream third-party analog to what `IrisCapture` is shipping. Adopted Swift 6 + AsyncStream for session events (didStart/didStop) — but **AsyncStream is for session lifecycle events, not for per-frame `CMSampleBuffer`s**. Worth reading their actor + delegate isolation pattern; do not depend on it (UIKit-shaped public API, no SwiftUI preview type).
- **MijickCamera** — https://github.com/Mijick/Camera · 622 ★ · last release 2025-09-30 (v3.0.3) · iOS only · "SwiftUI-first camera with Swift 6 support" · One of the few packages explicitly written for SwiftUI rather than retrofitted. README claims Swift 6 compatibility. Useful prior art for the `CameraPreview` view shape; check whether their preview is `UIViewRepresentable` or something they invented.
- **Apple AVCam sample (SwiftUI)** — https://developer.apple.com/documentation/avfoundation/avcam-building-a-camera-app · updated post-WWDC24, iOS 18 · Apple's reference implementation introduces a `CaptureService` actor + SwiftUI shell + LockedCameraCapture integration. This is the canonical pattern Iris should mirror; the Swift Forums consensus thread on safely using AVCaptureSession with Swift 6 strict concurrency lands on essentially the same architecture (actor wrapping session, delegates as private inner classes, AsyncStream for results, `nonisolated let` on the session itself, `@MainActor` ViewModel layer separate from capture service).
- **HaishinKit.swift** — https://github.com/HaishinKit/HaishinKit.swift · 3.0k ★ · last commit 2026-03-28 (v2.2.5) · iOS 15+, macOS 12+, tvOS 15+, visionOS 1+ · "Strict Concurrency / Swift 6 compliant streaming library with multi-camera, screen capture, video mixing" · **Surprisingly the only mainstream camera-related Swift package with serious macOS support.** Primary purpose is RTMP/SRT streaming (not Iris's job), but their AVCaptureSession-on-Swift-6 implementation across iOS+macOS is worth reading for cross-platform capture patterns. iOS overlap with Iris; macOS is interesting because Iris explicitly drops macOS camera capture.

### Playback (iOS + macOS)

- **AVPlayer + custom scrubber (gist family)** — https://gist.github.com/shaps80/ac16b906938ad256e1f47b52b4809512 · "Frame-by-frame scrubbing similar to Apple's apps" · No package, but the reference implementation for the kind of frame-step behavior `IrisPlayback` needs.
- **VideoTrimmerControl** — https://github.com/AndreasVerhoeven/VideoTrimmerControl · iOS-only, UIKit-based · Useful for the trim/scrub UI shape, but not a SwiftUI package. Read for UX patterns, don't depend.
- **(Otherwise empty.)** The curated lists don't surface a SwiftUI-first, async/await, iOS+macOS playback package that exposes an `AVAssetReader`-backed `AsyncStream<Frame>`. This is a real gap in the ecosystem — what `IrisPlayback` is filling. The Apple `VideoPlayer` view from AVKit is purely a UI surface; nothing in the awesome-* lists wraps `AVAssetReader` into an async sequence of frames suitable for ML pipelines.

### Detection

- **SwiftOCRKit** — https://github.com/DrcKarim/SwiftOCRKit · 21 ★ · last commit 2026-02-07 · iOS 15+, macOS 12+ · "async/await wrappers around Vision OCR" · A useful pattern-match for what an `IrisDetection` adapter should look like (clean `async let text = try await VisionOCR.recognizeText(from: image)` shape over Apple's pre-iOS-18 callback API). Tiny project but exactly the right *shape* — useful as a one-paragraph reference, not a dependency. Apple's iOS 18 Vision rewrite makes most of this obsolete anyway.
- **Apple's new Vision Swift API (iOS 18+)** — see Apple-frameworks section. The community-package detection space largely emptied out in 2024 because the new Apple API already does what most wrappers were doing.
- **(Otherwise mostly empty for SwiftUI-shaped, Swift-6-clean Detector wrappers.)** Roboflow's iOS SDK and Ultralytics yolo-ios-app cover the YOLO/RT-DETR side (yolo-ios-app is in the "already covered" list); nothing else in the awesome-* lists offers an iOS 18+ async Detector protocol of the shape Iris wants.

### Overlay

- **(No package candidates.)** Drawing bounding boxes is *always* shown as inline code in blog posts (Nicki Klein's Medium piece, machinethink.net, neuralception.com), never packaged. Every author re-derives Vision normalized-coords ↔ SwiftUI top-left coords ↔ AVCapture preview-layer coords from scratch. This is an unfilled niche; `IrisOverlay`'s coordinate-space module is genuinely something the ecosystem doesn't have packaged. Worth reading machinethink.net's "How to display Vision bounding boxes" as the canonical writeup of the transformation math.

### Tuning

- **(No package candidates.)** Nothing in the awesome-* lists for `@Observable`-based "tuning slider" / "what-if" UIs against ML/vision parameters. `@Observable` (iOS 17+) is well-documented (Donny Wals, SwiftLee, Sundell all have posts) but no one has packaged threshold/filter controls. Another unfilled niche.

### Dataset

- **(No package candidates.)** COCO JSON and YOLO sidecar formats are well-documented as a data spec (Roboflow's format pages, cocodataset/cocoapi for Python), but there is **no Swift package** for emitting them from device captures. The Apple Developer Forums and Roboflow blog both suggest using Create ML JSON instead, which is iOS-native but not the COCO standard. `IrisDataset` is filling another genuine ecosystem gap.

---

## Apple official frameworks that overlap Iris's territory

### Vision (framework)
- **Availability:** iOS 11+; the **new Swift API** is iOS 18+ / macOS 15+.
- **What it covers:** Pre-built `DetectBarcodesRequest`, `RecognizeTextRequest`, `RecognizeDocumentsRequest` (WWDC25 new), `DetectCameraLensSmudgeRequest` (WWDC25 new), hand pose, face landmarks, animal/human body pose, image classification, feature print, and arbitrary `CoreMLRequest` for custom models. Post-iOS-18 rewrite: renamed types (drop `VN` prefix), `async/await` perform methods, full Swift 6 / strict concurrency support, batch processing via Swift Concurrency.
- **Overlap with Iris:** Directly overlaps `IrisDetection`. The Apple Vision Swift API is essentially the canonical `Detector` protocol implementation; Iris's `Detector` should ideally compose Vision's `*Request` types as one backend, not reinvent them.
- **Community SPM wrapper:** SwiftOCRKit (above) for OCR, but the new API has gotten clean enough that wrappers are mostly redundant.
- **Verdict:** **Depend on it directly.** Vision is the primary backend Iris's `Detector` protocol should adapt. Document the protocol so a Vision-based detector is a one-liner.

### VisionKit (framework)
- **Availability:** iOS 13+ (VNDocumentCameraViewController); iOS 16+ (DataScannerViewController); iOS 17+ / macOS 14+ (ImageAnalyzer, ImageAnalysisInteraction, ImageAnalysisOverlayView — subject lifting, live text).
- **What it covers:** Document scanning, machine-readable codes + live text scanning UI, subject lifting (iOS 17+), image analysis interaction overlays.
- **Overlap with Iris:** Partial — DataScannerViewController is a UIKit alternative to building your own camera + Vision pipeline (and is iOS-only); ImageAnalysisOverlayView is the macOS-side overlay surface that's relevant to `IrisOverlay` on macOS for static images. **Subject lifting** is an interesting third-party capability Iris doesn't currently scope.
- **Community SPM wrapper:** None mature. Several blog posts wrap DataScannerViewController in `UIViewControllerRepresentable` for SwiftUI.
- **Verdict:** **Mostly ignore for v1; revisit subject lifting at M6.** DataScannerViewController is the *opposite* of what Iris is building (closed turnkey UI vs. composable pipeline). ImageAnalysisOverlayView is macOS-only static-image, so it's adjacent rather than overlapping.

### CoreML (framework)
- **Availability:** iOS 11+, macOS 10.13+, all platforms; ongoing per-OS additions (compute units, async loading, MLTensor, on-device fine-tuning, model collections).
- **What it covers:** Model loading, prediction, `MLModelConfiguration` (compute units: ANE/GPU/CPU), async loading (`MLModel.load(_:)` is async iOS 16+), model collections, asset-pack model delivery, on-device updating/personalization.
- **Overlap with Iris:** Backing technology for one branch of `IrisDetection`. Iris will likely have a `CoreMLDetector` adapter that wraps an `MLModel` and exposes it through `Detector`.
- **Community SPM wrapper:** None worth depending on; the Apple-generated Swift interface for a compiled `.mlmodelc` is already idiomatic.
- **Verdict:** **Depend on it directly.** It's the model-loading substrate. Most "CoreML wrapper" packages are obsolete — the generated interface and async loading already cover the ergonomics.

### Foundation Models (framework)
- **Availability:** iOS 26+, macOS 26+, visionOS 26+. Requires Apple Intelligence-enabled device.
- **What it covers:** On-device ~3B-parameter LLM, `SystemLanguageModel`, `LanguageModelSession`, guided generation (`@Generable`, `@Guide`), streaming responses, tool calling (custom `Tool` types), multimodal — vision encoder for image inputs (announced WWDC25, suitable for VLM-style use). Multi-turn stateful sessions.
- **Overlap with Iris:** Directly hits the M6 "captioner" question in the open design list. A `Captioner` protocol with a `FoundationModelsCaptioner` backend is one-screen-of-code, and `Detector` could in principle be backed by a guided-generation prompt for some workloads (though latency will be worse than Vision for bounding boxes).
- **Community SPM wrappers:**
  - **FoundationModelsTools** (https://github.com/rudrankriyam/FoundationModelsTools) — 135 ★, last commit 2026-02-17, iOS 26 / macOS 26 / Swift 6.2. Pre-built `Tool` adapters for Calendar, Contacts, HealthKit, Location, Music, Reminders, Weather, WebMetadata, WebTool. Not Iris-relevant (those are productivity tools, not vision), but a useful reference for how a community wraps Foundation Models in 2026.
  - **Foundation-Models-Framework-Example** (https://github.com/rudrankriyam/Foundation-Models-Framework-Example) — 1.0k ★, sample app (not a reusable package), iOS 26 / macOS 26. Comprehensive demo (multi-turn chat, structured generation, tools, voice, health, RAG). Worth skimming when wiring an Iris `FoundationModelsDetector` or `Captioner`.
  - **OpenFoundationModels** (https://github.com/1amageek/OpenFoundationModels) — 56 ★, last commit 2026-04-24 (v1.18.0), iOS 26 / macOS 26 / Swift 6.2. Independent implementation with 100% API compatibility with Apple's Foundation Models, backed by Claude / OpenAI / Ollama / MLX. Interesting as a *testing* surface (run Iris's captioner-on-the-CLI without Apple Intelligence hardware) but not a runtime dependency.
- **Verdict:** **Depend on Apple's Foundation Models directly for M6.** Read FoundationModelsTools for the public-API shape of a "Tool"-adapter pattern, but don't pull it in. OpenFoundationModels is interesting for CI/test environments without Apple Intelligence hardware — keep in mind as a future fixture, not a v1 dependency.

### DockKit (framework)
- **Availability:** iOS 17+, iPadOS 17+. iOS-only. No macOS.
- **What it covers:** Communication with motorized DockKit-compatible stands (Insta360 Flow Pro / Pro 2, etc.). iOS 17: multi-person tracker, motor control APIs. iOS 18: Intelligent Subject Tracking pipeline with an Apple-provided ML model that scores subjects on body pose, face pose, attention, speaking confidence. **Custom inference**: developers can supply their own inference model for tracking non-human/non-person objects.
- **Overlap with Iris:** Marginal but interesting. If Iris ever wants to "track-with-camera-motion" using a DockKit accessory, the custom-inference hook means `IrisDetection` outputs could feed DockKit's stand-control loop directly. Not a v1 milestone, possibly relevant at M6 or as a downstream app feature.
- **Community SPM wrapper:** None found.
- **Verdict:** **Ignore for v1; document as a downstream-app integration recipe.** Iris's job is the detection pipeline; DockKit consumes detections to point a motor. The seam is the `Detector` output — Iris should make sure its `Detection` type is shaped such that a DockKit consumer doesn't have to translate.

### AVFoundation / AVKit
- **Availability:** Universal. Modern: iOS 17+ added Zero Shutter Lag, Deferred Photo Processing, Responsive Capture; iOS 18 added more capture controls (WWDC25 session). AVKit's `VideoPlayer` SwiftUI view is iOS 14+ / macOS 11+.
- **What it covers:** Capture (`AVCaptureSession`, devices, inputs/outputs), playback (`AVPlayer`, `AVAssetReader`, `AVAssetImageGenerator`), AVKit's SwiftUI `VideoPlayer` view.
- **Overlap with Iris:** Foundational. `IrisCapture` *is* a Swift-6-clean SwiftUI shell over AVCaptureSession + AVCaptureVideoDataOutput. `IrisPlayback` *is* an AVAssetReader wrapped in an AsyncStream. There is no avoiding this dependency.
- **Community SPM wrapper:** NextLevel, MijickCamera, HaishinKit (above) all wrap parts of it; none expose the exact `AsyncStream<Frame>` shape Iris wants.
- **Verdict:** **Depend on it directly.** Iris is *the* SwiftUI/async wrapper for the Iris use case. Read Apple's AVCam sample as the architectural reference.

### Create ML / Create ML Components
- **Availability:** macOS 10.14+ (Create ML), iOS 15+ / macOS 12+ (Create ML Components), iOS 17+ / macOS 14+ (on-device personalization extras).
- **What it covers:** Model training (object detection, classification, sound, action, hand pose, style transfer) and component-based pipeline construction. On-device training/fine-tuning.
- **Overlap with Iris:** Tangential — Create ML is the *producer* of `.mlmodel` files; Iris consumes them via CoreML. Create ML's **annotation JSON format** is the actual Apple-blessed sidecar format for object detection datasets — relevant tension with the `IrisDataset` COCO-vs-YOLO open question (consider Create ML JSON as a third option, since it's iOS-native and round-trips into the training tool).
- **Community SPM wrapper:** N/A — Create ML is a macOS app + framework, not something to wrap.
- **Verdict:** **Ignore as a dependency, but reconsider Create ML JSON as the dataset sidecar format** — it's the lowest-friction path from `IrisDataset` capture to a trainable Apple object-detector. Open design question #3 should explicitly weigh Create ML JSON alongside COCO and YOLO.

---

## Considered but dropped

- **CameraKit-iOS** (https://github.com/CameraKit/camerakit-ios · 737 ★) — last release July 2019. Unmaintained, UIKit, callback-based.
- **Camera-SwiftUI** (https://github.com/rorodriguez116/Camera-SwiftUI · 267 ★) — last commit August 2022. Pre-SwiftUI-async patterns, iOS-only, dormant.
- **SwiftyCam** (https://github.com/Awalz/SwiftyCam) — Snapchat-style camera, hasn't been updated in years, UIKit.
- **MediaPicker / Fusuma / YPImagePicker** — photo/video picker UIs, not capture pipelines. Out of scope for Iris (Iris owns capture, not picking).
- **GPUImage 3 / Harbeth** — GPU image filtering pipelines. Adjacent to but not overlapping `IrisCapture` (Iris doesn't need filters in v1).
- **ARVideoKit** (https://github.com/AFathi/ARVideoKit) — ARKit video capture, not the same problem.
- **Bender / Forge / Swift-AI / DL4S** — Older Metal-based NN frameworks, mostly pre-CoreML era; superseded by CoreML + Apple Neural Engine.
- **coremltools / tf-coreml / onnx-coreml** — Python tooling for model conversion. Adjacent (lives one step before Iris's pipeline) but not a Swift dependency.
- **SwiftCoreMLTools** (https://github.com/JacopoMangiavacchi/SwiftCoreMLTools) — Swift library for *generating* CoreML models; orthogonal to Iris's job (consuming them).
- **MochiDiffusion / FluidAudio** — Top-of-topic Swift+CoreML projects, but diffusion image generation (MochiDiffusion) and audio ML (FluidAudio) are off-domain.
- **VideoTrimmerControl** — UIKit-only trimming UI. Useful UX reference, not a SwiftUI dependency.
- **Roboflow Swift SDK** — Closed-source-ish, dataset-platform-specific. The SDK pattern (RT-DETR / YOLO via CoreML) is interesting reference; SDK itself ties Iris to one vendor.

---

## Notable web sources

- **WWDC25 sessions (most relevant to Iris):**
  - 272 — "Read documents using the Vision framework" — https://developer.apple.com/videos/play/wwdc2025/272/
  - 286 — "Meet the Foundation Models framework" — https://developer.apple.com/videos/play/wwdc2025/286/
  - 301 — "Deep dive into the Foundation Models framework" — https://developer.apple.com/videos/play/wwdc2025/301/
  - 259 — "Code-along: Bring on-device AI to your app using Foundation Models" — https://developer.apple.com/videos/play/wwdc2025/259/
  - 248 — "Explore prompt design & safety for on-device foundation models" — https://developer.apple.com/videos/play/wwdc2025/248/
  - WWDC25 capture-controls session — https://dev.to/arshtechpro/wwdc-2025-enhancing-your-camera-experience-with-capture-controls-3mfo
- **WWDC24 sessions still highly relevant:**
  - 10163 — "Discover Swift enhancements in the Vision framework" — https://developer.apple.com/videos/play/wwdc2024/10163/ (the Vision Swift API rewrite — *the* reference for `IrisDetection`)
  - 10164 — "What's new in DockKit" — https://developer.apple.com/videos/play/wwdc2024/10164/
- **Swift Forums (essential reading for `IrisCapture`):**
  - https://forums.swift.org/t/safely-use-avcapturesession-swift-6-2-concurrency/83622 — Dec 2025 consensus thread on actor-wrapping AVCaptureSession under Swift 6 strict concurrency. Direct architectural reference for Iris.
  - https://forums.swift.org/t/avcapturesession-and-concurrency/72681 — earlier discussion of the same problem.
- **Blogs / tutorials (good context, not load-bearing):**
  - https://en.zhgchg.li/posts/kkday-tech-blog/ios-vision-framework-explore-swift-api-enhancements-from-wwdc-24-session-755509180ca8/ — clean walkthrough of the iOS 18 Vision API rename + async refactor
  - https://www.createwithswift.com/exploring-the-foundation-models-framework/ — practical Foundation Models intro
  - https://swiftwithmajid.com/2025/08/19/building-ai-features-using-foundation-models/ — Majid Jabrayilov's Foundation Models walkthrough
  - https://machinethink.net/blog/bounding-boxes/ — the canonical "how to display Vision bounding boxes" piece; coordinate-space transformation math for `IrisOverlay`
  - https://www.donnywals.com/observable-in-swiftui-explained/ + https://www.avanderlee.com/swiftui/observable-macro-performance-increase-observableobject/ — `@Observable` references for `IrisTuning`
- **Apple sample code references:**
  - https://developer.apple.com/documentation/avfoundation/avcam-building-a-camera-app — the SwiftUI + `CaptureService` actor sample; the architectural reference for `IrisCapture`

---

## Notes / surprises

1. **Apple has eaten the "Detection wrapper" space.** The iOS 18 Vision Swift API rewrite (clean type names, async/await, Swift 6 ready, Swift Concurrency-aware batch processing, plus WWDC25 additions like `RecognizeDocumentsRequest` and `DetectCameraLensSmudgeRequest`) made most pre-2024 community Vision wrappers obsolete. The community-package detection layer has nearly emptied out. SwiftOCRKit (21 ★, Feb 2026) is what's left, and it's a thin OCR convenience that's barely needed under the new API. Iris's `Detector` protocol is therefore largely a *composition* problem (Vision + CoreML + Foundation Models behind one protocol), not a "fill in what Apple is missing" problem.

2. **There is no `awesome-vision` for Apple's Vision framework.** The two `awesome-visionos` lists are about the Vision Pro headset, not the Vision framework. The vision/CoreML/camera community lives on Swift Package Index, GitHub topic search, individual blogs (createwithswift.com, Donny Wals, SwiftLee, Hacking with Swift), and Apple sample code. No single curated entry point.

3. **Overlay coordinate-space conversion is genuinely unpackaged.** Every blog post (machinethink, NeuralCeption, Medium pieces) re-derives Vision normalized ↔ AVCapture preview ↔ SwiftUI top-left from scratch, with rotation and mirroring quirks each rediscovered. `IrisOverlay`'s coordinate-space module is one of the real gaps Iris is filling. Worth being defensive about the public-API shape here — this is the part future Iris users will most often poke at.

4. **macOS camera packages basically don't exist beyond HaishinKit.** HaishinKit (3k ★, streaming-oriented) is the only mainstream Swift package with serious cross-platform `AVCaptureSession` support. This validates Iris's "no macOS camera capture" decision — the ecosystem hasn't solved this, and the prevailing pattern (Apple's AVCam sample, NextLevel, MijickCamera) is iOS-only. macOS-on-Iris is correctly scoped to playback/inference/dataset.

5. **AsyncStream wrapping of AVCaptureVideoDataOutput is consensus-but-unpackaged.** The Swift Forums thread (Dec 2025) converges cleanly on an actor + private delegate + `AsyncStream<T>` pattern, and NextLevel adopts this for *session events*, but **nobody has packaged the per-frame `AsyncStream<CMSampleBuffer>` flavor specifically**. This is the heart of what `IrisCapture` ships. The pattern is well-understood; the packaging is the contribution.

6. **Foundation Models community wrappers are *immature but moving fast*.** Three notable packages (FoundationModelsTools, OpenFoundationModels, Foundation-Models-Framework-Example) in ~9 months since GA. Tools-style adapters (FoundationModelsTools) are the dominant pattern. There is **no Vision-language captioning package** wrapping Foundation Models' multimodal capability yet — that's still a "read Apple's sample app and wire it yourself" affair. M6 captioning is therefore both feasible (the framework is real, multimodal exists) and novel (nobody else has shipped this pattern).

7. **Create ML JSON is the sleeper for `IrisDataset`.** Open design question #3 (COCO vs. YOLO sidecar) should probably include Create ML JSON as a third option. It's the iOS-native, Apple-blessed annotation format, round-trips into Apple's own training tool, and Roboflow already exports to it. COCO is the cross-tool standard; Create ML JSON is the lowest-friction path on Apple hardware. Worth surfacing this when M5 lands.

8. **The Apple AVCam SwiftUI sample is the implicit gold standard.** The Swift Forums thread, every recent tutorial, and Iris's `IrisCapture` spec all converge on the same architecture: a `CaptureService` actor, `AsyncStream` for results, `@MainActor` ViewModel separate from capture, `nonisolated let` on the session, private inner-class delegates. This is now the de-facto pattern. Iris should mirror it explicitly, with a one-line note in the module docs pointing at the AVCam sample as the reference implementation.
