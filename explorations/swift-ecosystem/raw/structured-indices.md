# Structured-indices scan — Swift package candidates

**Date:** 2026-05-20
**Sources walked:**

Swift Package Index keyword pages: `/keywords/vision`, `/keywords/coreml`, `/keywords/camera`, `/keywords/avfoundation` (pages 1+2), `/keywords/video` (page 1), `/keywords/machine-learning`, `/keywords/computer-vision`, `/keywords/object-detection` (404 — keyword has no page), `/keywords/foundation-models`.

Swift Package Index searches: `?query=yolo`, `?query=detector`, `?query=swiftui-camera`, `?query=VNCoreMLRequest`, `?query=COCO`, `?query=playback`, `?query=overlay`.

GitHub topic / keyword API queries (sorted updated, per_page=30): `topic:coreml language:swift`, `topic:vision language:swift`, `topic:object-detection language:swift`, `topic:swiftui-camera`, `topic:avfoundation language:swift`, `yolo language:swift`. GitHub topic pages (`github.com/topics/...`) for `coreml`, `swiftui-camera`, `avfoundation`. Detail pages on SPI for the top candidates (Mijick/Camera, atelier-socle/swift-capture-kit, SteliyanH/kadr, NextLevel, AsyncGraphics, Pillarbox) for README/platform/Swift-6 confirmation.

The `keywords/object-detection` keyword does not exist on SPI (404); `keywords/swiftui-camera` exists but only as a tag on `Mijick/Camera`. There is no `topic:swift-vision` or `topic:vncoreml` (both return zero results). `topic:swift-package + camera` and most narrow combo queries are not supported by GitHub's search syntax — keyword search with star/recency sort was the workable substitute.

---

## Candidates worth deep-reading

### Capture (iOS)

- **NextLevel** — github.com/NextLevel/NextLevel · last commit 2026-02 (latest tag 0.19.0 released ~4 months ago, dev branch 3 months ago) · **2,306 stars** · iOS 16+ / Swift 6 strict concurrency, AsyncStream events, async/await, MIT · *Singleton-shared `NextLevel.shared` UIKit-style API with delegates and per-frame `CVPixelBuffer` hooks (`renderToCustomContextWithImageBuffer`); the most battle-tested AVCaptureSession wrapper in the SPM ecosystem, but UIKit-flavored — would need a SwiftUI shim layer to fit Iris's "public API is SwiftUI-shaped" rule. Strong reference for Swift 6 migration of an AVFoundation pipeline (changelog covers exactly the gotchas: AudioChannelLayout crash, sample-buffer Sendable issues, interruption handling).*

- **MijickCamera** — github.com/Mijick/Camera · last commit ~2025-09 (last release 3.0.3, 7 months ago) · **622 stars** · iOS 14+ "written with and for SwiftUI", Apache 2.0, zero data-race errors on SPI builds · *The closest existing analog to `IrisCapture` — a `MCamera` SwiftUI view that wraps the whole capture session. But it's an opinionated full-screen camera app shell (built-in controls, gestures, capture review screen) rather than a thin `AsyncStream<Frame>` primitive. Iris needs the bottom half (session lifecycle, preview, frame stream) without the top half (camera UI). Worth reading for the SwiftUI surface pattern; not a dep candidate.*

- **swift-capture-kit** — github.com/atelier-socle/swift-capture-kit · last commit 2026-05-16 · **4 stars** · iOS+macOS+visionOS, Swift 6.2, Apache 2.0, zero data-race errors · *Brand new (2 months old, v0.1.2). Self-describes as "Unified media capture, encoding & streaming for Apple platforms — every source, every codec, zero dependencies." Could collide directly with Iris's `IrisCapture` charter if it matures. Tiny audience (4 stars) means real Iris should not adopt as a dep, but should monitor — and read README closely for what the author already encountered re: Sendable boundaries across capture session, encoder, and stream.*

- **Aespa** — github.com/enebin/Aespa · last commit ~2024-Q1 (almost 2 years ago) · **136 stars** · iOS · *"From camera to album, just 2 lines." Cited often in iOS-camera roundups but now dormant. Listing for completeness — drop in the dropped section in practice.*

- **HaishinKit** — github.com/HaishinKit/HaishinKit.swift · last commit ~2026-05 · **3,043 stars** · iOS+macOS+tvOS+visionOS · *Camera + microphone streaming via RTMP/SRT. Way outside Iris's scope (streaming protocol stack) but it's a useful reference for AVCaptureSession plumbing on multiple platforms in a Swift 6 codebase. Not a candidate dep.*

### Playback (iOS+macOS)

- **Pillarbox** — github.com/SRGSSR/pillarbox-apple · last commit 2026-05-20 (hours ago) · **103 stars** · iOS+macOS+tvOS+visionOS, MIT, has DocC · *"Next-generation reactive media playback ecosystem for Apple platforms." Maintained by Swiss public broadcaster SRG SSR — production grade, actively shipped, real cross-platform coverage. But this is an `AVPlayer`-oriented streaming/broadcast playback stack, not the frame-pumping `AVAssetReader → AsyncStream<Frame>` shape Iris needs for inference. Worth reading for how a serious cross-platform Apple media stack structures itself; not a dep candidate for `IrisPlayback`.*

- **Kadr** — github.com/SteliyanH/kadr · last commit 2026-05-19 · **41 stars** · iOS 16+ / macOS 13+ / tvOS 16+ / visionOS 1+, Swift 6.0, Apache 2.0, no third-party deps, zero data-race errors · *Declarative video *composition* (DSL: `Video { ImageClip(...); Transition.dissolve(...) }.export(to:)`), not playback. But it's a fresh, well-architected, Swift-6-strict-concurrency, async/await-throughout AVFoundation library — the closest published example of "the codebase shape Iris is aiming for." Multiple companion packages (`kadr-ui`, `kadr-captions`, `kadr-photos`) prove the multi-target-with-platform-scoped-adapters pattern Iris is using. Read the README + `ARCHITECTURE` section as a reference, not a dep.*

- **swiftui-loop-videoplayer** — github.com/swiftuiux/swiftui-loop-videoPlayer · last commit ~2026-01 · **98 stars** · macOS+iOS+tvOS · *Looping `AVPlayer` wrapper in SwiftUI. Mentioned only because it's one of the few SwiftUI-first playback packages on SPI; doesn't expose frame-level access, so not relevant for `IrisPlayback`.*

### Detection

- **SwiftTasksVision** — github.com/paescebu/SwiftTasksVision · last commit 2026-04-10 · **30 stars** · iOS 13+ (intentionally low floor), MIT · *Swift Package Manager wrapper around Google MediaPipe Tasks Vision (auto-updated daily by a GitHub Action tracking the upstream MediaPipe pod). Not a Detector protocol — wraps Google's whole MediaPipe runtime. Useful as a reference for "what if Iris wants a second backend that isn't Vision/CoreML." iOS-only despite MediaPipe itself being cross-platform.*

- **YOLO (fatihdurmaz/yolo-ios-sdk)** — github.com/fatihdurmaz/yolo-ios-sdk · last commit ~2024-Q4 (over 1 year ago) · **17 stars** · iOS · *The only thing on SPI search that returns for `query=yolo`. Dormant. Listing because it confirms: there is no other generic, SPM-distributed YOLO/Detector library on the index beyond Ultralytics' own demo app (already covered).*

- **SemanticImage** — github.com/john-rocky/SemanticImage · last commit 2026-05-13 · **157 stars** · iOS+macOS, Vision + CoreML built on Apple frameworks · *"Collection of easy-to-use image/video filters" — wraps Vision and CoreML for common tasks (segmentation, person/face/object detection, depth). Closer to a utility kit than a `Detector` protocol, but the active author (john-rocky) ships several adjacent on-device-ML packages worth tracking.*

- **PrivateFoundationModels** — github.com/john-rocky/PrivateFoundationModels · last commit 2026-05-14 (6 days ago) · **4 stars** · iOS 18+ · *"Apple FoundationModels API on iOS 18+. Same call site, native passthrough on iOS 26 (Apple Intelligence), CoreML / MLX backends on older OSes. Drop-in source compatible." Directly relevant for the Iris open question #6 ("Foundation Models as a Detector backend vs. a separate Captioner protocol"). Tiny audience but exactly the shape ("one call site, polymorphic backend") Iris is contemplating for its Detector protocol.*

- **mlx-swift-vision** — github.com/petrukha-ivan/mlx-swift-vision · last commit 2026-04-05 · **3 stars** · *"Computer vision in Swift" using MLX. Listing because it's the only SPM-shaped attempt to bring MLX (Apple Silicon-native) into a vision pipeline — relevant if Iris adds a third backend alongside Vision and CoreML. Very small / early.*

### Overlay

Nothing worth deep-reading. The `query=overlay` results are all SwiftUI bottom-sheet / coach-mark / debug-overlay packages, none of them about drawing detections over a video frame with normalized-coords-to-view-coords conversion. The detection coordinate-space conversion problem (Vision normalized + mirroring + rotation → SwiftUI view coords) is not solved as a reusable SPM package anywhere on the index. **This is a real gap in the ecosystem, and a real product opportunity for `IrisOverlay`.**

### Tuning

Nothing. There is no SPM package that ships an `@Observable` threshold / NMS / filter control surface over a generic Detector. Closest adjacent is **Mentalist** (enebin/Mentalist, 19 stars, over 1 year ago — emotion read with one line) but it's a one-shot helper not a tuning layer. **Another real gap**, and reinforces that `IrisTuning` is greenfield work — there isn't a "use this instead" answer hiding on the index.

### Dataset

Nothing. SPI search for `COCO` returns CocoaPods-related results (the substring matches "cocoa"); no Swift package surfaces COCO JSON serialization, YOLO `.txt` sidecars, or one-tap frame-export sinks. There is no SwiftPM package for Pascal VOC either. **This is the third real gap** — Iris's `IrisDataset` is the only player in this space if it ships.

---

## Considered but dropped

### Capture
- **NextLevelSessionExporter** — github.com/NextLevel/NextLevelSessionExporter · 276 stars · 2026-04 · *Sibling of NextLevel; pure export/transcode, not capture. Out of Iris scope (exporters are a downstream concern).*
- **HaishinKit** — already noted above; demoted because RTMP/SRT streaming is well outside Iris scope.
- **CameraManager** — github.com/imaginary-cloud/CameraManager · 1,400 stars · 2024 (2 years ago) · *Dormant; iOS-only UIKit class.*
- **CameraView** — github.com/brettfazio/CameraView · 80 stars · 5 years ago · *Abandoned.*
- **SwiftUICamera** — github.com/k-arindam/SwiftUICamera · 21 stars · 10 months ago · *Minimal; "Seamless camera integration for SwiftUI" but no Swift 6, no async stream, no real architecture; Mijick/Camera dominates this slot.*
- **AVCaptureViewModel** — github.com/edonv/AVCaptureViewModel · 1 star · 2 years ago · *Hobby tier.*
- **SwiftCameraKit** — github.com/nicolaischneider/SwiftCameraKit · 5 stars · ~1 year ago · *Small hobby package.*
- **CameraKage**, **CameraButton**, **CameraCapture** (samst-one) — all small/dormant/hobby.
- **AVFoundationCombine** — github.com/jozsef-vesza/AVFoundation-Combine · 30 stars · 5 years ago · *Combine extensions; Iris is going async/await, not Combine.*
- **BroadcastWriter**, **kubrick** — 3–8 years dormant.
- **Aespa** — kept in Capture above as the dormant-but-name-recognized reference; functionally dropped.
- **PermissionsKit** (sparrowcode) — 5,814 stars · 2 months ago · *Universal permissions wrapper; orthogonal to camera-pipeline work but might be useful for a demo app. Out of Iris scope.*

### Playback / video
- **AsyncGraphics** — github.com/heestand-xyz/AsyncGraphics · 417 stars · 2026-05-18 · iOS+macOS, Swift 6 concurrency · *"Edit images and video with Swift concurrency, powered by Metal." Production-grade, but it's a graphics/processing toolkit (apply filters / blend / generate), not a frame-source library. Could be useful inside `IrisOverlay` for GPU-accelerated overlay rendering, but it's a heavy dep for what Iris needs. Worth a brief look in the synthesis, not a deep read.*
- **Player** (piemonte) — 2,163 stars · 2 months ago · *AVPlayer wrapper, UIKit-shaped, no frame stream.*
- **HLSVideoCache**, **VideoIO**, **morsel**, **SwiftFFmpeg**, **SwiftVLC** — all about codecs/transport, not frame iteration.
- **LiveKit**, **StreamVideo** (GetStream), **Pillarbox-castor**, **VideoEditorSDK** — commercial / SDK-flavor, out of scope.
- **YouTubeKit** — extractor, not relevant.
- **swiftui-background-video**, **SwiftUIBackgroundVideo** — looping decoration, not relevant.

### Detection / ML
- **executorch** (pytorch/executorch) — 4,641 stars · 9 hours ago · *PyTorch's on-device runtime; cross-platform but not "use this as my Detector" — it's a much lower layer.*
- **ggml** (ggml-org) — 14,666 stars · 9 hours ago · *Same: low-level C tensor lib, not a Swift Detector.*
- **FluidAudio** (FluidInference) — 2,051 stars · 1 day ago · *Audio (TTS / STT / VAD / diarization). Wrong modality.*
- **Qwen3Speech** (soniqo/speech-swift) — 740 stars · 13h ago · *Audio.*
- **Wax** (christopherkarani/Wax) — 737 stars · 1 day ago · *On-device RAG / vector memory; wrong domain.*
- **swift-embeddings**, **SimilaritySearchKit**, **Conduit**, **LocalLLMClient**, **olleh**, **Swarm**, **SwiftMCP**, **swift-llama**, **swift-tiktoken**, **TranscriptDebugMenu**, **SwiftFM** — all LLM / embedding / agent infrastructure; not detection.
- **Mentalist** — emotion-read one-liner, hobby-tier.
- **MNISTKit** — 22 stars · 8 years ago · *Reference relic.*
- **VisionFaceAware** — 13 stars · 3 years ago · *UIImageView face-crop extension.*
- **Evil** (evilgix) — 694 stars · 4 years ago · *OCR; dormant.*
- **SwiftOCRKit** (DrcKarim) — 21 stars · 2 months ago · *Async OCR over Apple Vision; narrow scope but if Iris ever adds an OCR Detector, this is the obvious starting reference. Demoted from candidates because OCR isn't on the Iris milestone path.*
- **SwiftAprilTag** — 0 stars · 11 days ago · *AprilTag fiducial wrapper; useful niche reference but very early.*
- **john-rocky/CoreML-Models** — 1,762 stars · 2026-05-13 · *Model zoo, not a Swift package — just `.mlmodel` files.*

### Overlay
- All overlay-named SPI hits are sheet/coach-mark/debug-overlay packages and none have anything to do with detection-on-frame rendering. Dropped without listing.

### Foundation Models
- **olleh** (mattt/olleh) — 179 stars · 7 months ago · *Ollama-compatible CLI on top of Apple Foundation Models. CLI, not a library a SwiftUI app embeds.*
- **TranscriptDebugMenu** (artemnovichkov) — 17 stars · 27 days ago · *Debug UI for `LanguageModelSession` transcripts. Cute but very narrow.*
- **swift-context-management** (Silo-Labs) — 11 stars · 3 months ago · *Context window pruning; LLM infra, not detection/captioning.*

---

## Sources hit (audit trail)

- https://swiftpackageindex.com/keywords/vision — 7 packages; meaningful hits: NextLevel (cross-listed), SemanticImage, SwiftOCRKit, VisionFaceAware (dormant), Evil (dormant), Grayskull (niche). No "Detector" protocol on the page.
- https://swiftpackageindex.com/keywords/coreml — 12 packages; dominated by audio/embedding/LLM packages. Vision-relevant: SemanticImage, PrivateFoundationModels. The CoreML keyword has been captured by on-device LLM crowd; classic CV/CoreML is not the dominant cluster anymore.
- https://swiftpackageindex.com/keywords/camera — 18 packages; the densest signal. Mijick/Camera (622 stars) is the clear SwiftUI-first leader, NextLevel (2,306) is the established UIKit-leaning leader, HaishinKit (3,043) is the streaming-stack leader.
- https://swiftpackageindex.com/keywords/avfoundation (pages 1+2) — ~25 packages; reinforced same trio (NextLevel, MijickCamera, Pillarbox); also surfaced swift-capture-kit (atelier-socle), Kadr (SteliyanH), PersonaCam (robomex, visionOS only).
- https://swiftpackageindex.com/keywords/video — 20 packages; Pillarbox + StreamVideo + LiveKit + Kadr + AsyncGraphics + a long tail of niche players. No `AVAssetReader` → frame-stream package surfaced.
- https://swiftpackageindex.com/keywords/machine-learning — 19 packages; dominated by LLM and tensor-lib wrappers. No vision-specific detector library.
- https://swiftpackageindex.com/keywords/computer-vision — only 2 packages on the entire keyword: SwiftAprilTag (0 stars, 11 days) and SwiftOCRKit (21 stars, 2 months). **The keyword is essentially abandoned on SPI.**
- https://swiftpackageindex.com/keywords/object-detection — 404, keyword does not exist. **Strong signal that no one self-tags this way.**
- https://swiftpackageindex.com/keywords/foundation-models — 8 packages, all LLM-side; nothing using FM as a vision/captioning backend (PrivateFoundationModels is on the `coreml` keyword instead).
- https://swiftpackageindex.com/search?query=yolo — 1 real hit (fatihdurmaz/yolo-ios-sdk, dormant). Confirms: no live SPM-distributed YOLO/Detector wrapper.
- https://swiftpackageindex.com/search?query=detector — none of the matching packages are CV detectors (all QR-code, jailbreak, charset, device, story-format, leak detectors). **The word "Detector" in the SPM ecosystem means runtime/environment detection, not ML detection.**
- https://swiftpackageindex.com/search?query=COCO — every match is a CocoaPods substring; no COCO-format library.
- https://swiftpackageindex.com/search?query=playback — Pillarbox, swiftui-loop-videoplayer, AudioVisualService, HLSVideoCache; nothing frame-iteration.
- https://swiftpackageindex.com/search?query=overlay — all sheet/coach-mark/debug; nothing detection-overlay.
- https://swiftpackageindex.com/search?query=swiftui-camera — minimal (one MijickCamera hit).
- https://swiftpackageindex.com/search?query=VNCoreMLRequest — zero relevant results.
- SPI detail pages (full READMEs / metadata): NextLevel, Mijick/Camera, atelier-socle/swift-capture-kit, SteliyanH/kadr, SRGSSR/pillarbox-apple, heestand-xyz/AsyncGraphics — confirmed Swift 6 / strict concurrency / iOS-target floors and architectural shape.
- GitHub API: `topic:coreml language:swift` (sorted updated, 30 results), `topic:vision language:swift` (30), `topic:object-detection language:swift` (30), `topic:swiftui-camera` (3 results total — a sparse topic), `topic:avfoundation language:swift` (30), `yolo language:swift` (30 — mostly forks of ultralytics/yolo-ios-app). The `topic:vision` results are dominated by individual indie apps (Ollama clients, dictation tools, screenshot+OCR utilities) — very few are reusable Swift packages.
- GitHub topic pages (UI-rendered, via firecrawl): `github.com/topics/coreml`, `/topics/swiftui-camera`, `/topics/avfoundation` — confirms the API findings; nothing new surfaced.
- After ~10 API calls, GitHub rate-limited the IP (60/hour unauth); switched to UI scraping for additional GH walks.

---

## Notes / surprises

**Three real gaps in the ecosystem.** There is **no** SwiftPM package for:
1. SwiftUI overlay views that render `[Detection]` with Vision-normalized-to-view-coord conversion (rotation, mirroring, aspect mismatch).
2. `@Observable` tuning controls layered over a generic Detector (NMS, thresholds, filter chains).
3. Dataset capture / COCO sidecar / one-tap-frame-to-disk sinks.

These map exactly to Iris's `IrisOverlay`, `IrisTuning`, and `IrisDataset` modules. Iris is unique in shipping all three. There is no "use this instead" hiding on the index for any of them — the synthesis can be confident these are greenfield work.

**The "computer-vision" and "object-detection" SPI keywords are essentially empty** (2 packages and a 404 respectively). The reusable-CV-on-Apple ecosystem mostly exists as one-off iOS apps on GitHub, not as SwiftPM libraries. This is consistent with the lay-of-the-land assumption behind Iris.

**The "CoreML" keyword has been captured by the on-device-LLM crowd.** 8 of the top 12 results are audio / embedding / RAG / LLM infrastructure (FluidAudio, Wax, swift-embeddings, etc.). Classic vision-CoreML packages are sparse and most are old. PrivateFoundationModels (4 stars, john-rocky, 6 days ago) is the only fresh example of someone treating Foundation Models / CoreML / MLX as interchangeable inference backends — which is exactly Iris's `Detector` design pattern.

**The "Detector" word is taken.** In Swift package metadata it means runtime/environment detection (QR codes, charsets, device models, jailbreak, leaks). When `IrisDetection` ships, the protocol name `Detector` will be unique-enough by import context but search-ambiguous; consider documentation that anchors it to "vision/object detector" explicitly.

**Capture is the most contested area.** Three live candidates (NextLevel 2.3k stars + Swift 6, MijickCamera 622 + SwiftUI-first, swift-capture-kit 4 stars + Swift 6.2 + brand new). None has the exact shape Iris wants (`AsyncStream<Frame>` from a SwiftUI-wrapped session, iOS-only, with macOS deliberately excluded). The closest fit is MijickCamera's SwiftUI surface combined with NextLevel's per-frame `imageBuffer` hook — Iris's `IrisCapture` design should explicitly position against both.

**Kadr (SteliyanH) is the strongest stylistic reference** for the codebase shape Iris is aiming for: Swift 6, iOS 16+, no third-party deps, async/await throughout, zero data-race errors, multi-target with `kadr-ui` / `kadr-captions` / `kadr-photos` companion packages mirroring Iris's `IrisOverlay` / `IrisDataset` adapter pattern. Different domain (video composition vs. CV) but the architecture and ergonomics map almost 1:1 — read its README and CHANGELOG for v0.10/v0.11/v0.12 to see how a Swift 6 strict-concurrency multi-target package handles real-world migration pain.

**swift-capture-kit (atelier-socle, 4 stars, 4 days old) is the existential-threat candidate** to read carefully — it self-describes as "Unified media capture, encoding & streaming for Apple platforms — every source, every codec, zero dependencies. Pure Swift 6.2." Its scope partially overlaps `IrisCapture`. The 4-star audience means it's not gravity yet, but it could become so. Reading its `Package.swift`, public surface, and (especially) how it handles cross-platform `#if os` divergence would inform Iris's positioning.

**No Foundation Models vision/captioning packages exist yet.** The `foundation-models` SPI keyword is all LLM infra (Conduit, LocalLLMClient, Swarm, etc.). PrivateFoundationModels is the only one that even hints at "FM as one swappable backend among CoreML/MLX." This makes Iris open question #6 (FM as a Detector backend vs. a separate Captioner protocol) a genuinely open ecosystem question — there is no prior art to imitate or extend.

---

## Already covered (from `explorations/prior-projects/`, surfaced and skipped during this scan)

- **ultralytics/yolo-ios-app** — appeared repeatedly in `topic:object-detection language:swift` and the `yolo` keyword search (472 stars · 2026-05-20). Confirmed seen, skipped per instructions.
- `ios-videoCapture`, `PRVisionSpike`, `sportvision`, and the Apple `BuildingAFeatureRichAppForSportsAnalysis` (ActionAndVision) sample — none surfaced in any of the SPI keyword/search pages or GitHub topic queries above (they aren't SPM packages, so this is expected). Confirmed not duplicated.
