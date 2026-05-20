# PrivateFoundationModels — prior-art read

**Path:** github.com/john-rocky/PrivateFoundationModels · 4★ · iOS 18+ / macOS 15+ / visionOS 2+
**Read date:** 2026-05-20
**Priority lens:** polymorphic backend pattern — one API, multiple inference backends (Apple FM / CoreML / MLX)

## At a glance

A surprisingly mature project for 4 stars. ~2,100 lines in the public core module (`Sources/PrivateFoundationModels/`), plus three backend modules (Apple, CoreML, MLX), three OpenAI-compatible HTTP server executables, three benchmark exes, and an end-to-end "portability proof" exe. Last commit 2026-05-14 (`v0.11.0: LoRA / DoRA adapter loading on the MLX backend`).

Package layout (`Package.swift:1-363`):

- `PrivateFoundationModels` — pure-Swift core. **Zero runtime deps** other than its own macro plugin. Exports `LanguageModelSession`, `Instructions`, `GenerationOptions`, `Transcript`, `Tool`, `Generable`, `SystemLanguageModel`, plus the `LanguageModelBackend` protocol that backends conform to.
- `PrivateFoundationModelsApple` — passes through to Apple's `FoundationModels` on iOS 26+ (gated by `#if canImport(FoundationModels)` + `@available(iOS 26.0, …)`).
- `PrivateFoundationModelsCoreML` — adapts `john-rocky/CoreML-LLM`.
- `PrivateFoundationModelsMLX` — adapts `ml-explore/mlx-swift-lm`.

The core module has **no idea** any of the backends exist; it depends on none of them. Backend modules depend on core.

## Capture / Frame plumbing

N/A — language-model framework, not a vision pipeline. **But** multimodal input is interesting for Iris: `BackendAttachment` (`Sources/PrivateFoundationModels/BackendAttachment.swift:10-20`) is a single-case enum wrapping a `CGImage`:

```swift
public struct BackendAttachment: Sendable {
    public enum Kind: @unchecked Sendable { case image(CGImage) }
    public let kind: Kind
    public init(image: CGImage) { self.kind = .image(image) }
}
```

It threads through the session as a *separate parameter* (`respond(to: String, image: CGImage?, options:)` on `LanguageModelSession.swift:166-174`), not as a chunk inside the transcript. **Image-in / text-out — the canonical VLM shape.** Audio is "v0.8 roadmap" per a comment.

## Inference async pattern (priority lens)

The whole package crystallizes around one protocol — `LanguageModelBackend` (`Sources/PrivateFoundationModels/LanguageModelBackend.swift:12-86`):

```swift
public protocol LanguageModelBackend: Sendable {
    var availability: SystemLanguageModel.Availability { get }
    var modelIdentifier: String { get }
    func prewarm() async
    func generate(transcript: Transcript, options: GenerationOptions,
                  schema: GenerationSchema?, tools: [AnyTool]) async throws -> BackendGeneration
    func streamGenerate(transcript: Transcript, options: GenerationOptions,
                        schema: GenerationSchema?, tools: [AnyTool])
        -> AsyncThrowingStream<BackendDelta, Error>
    // …multimodal variants with default impls that drop attachments and call the text-only ones…
    func tokenCount(_ text: String) async -> Int?
}
```

Five things to note:

1. **Protocol with conformers, not an enum.** Backend type is open — any third-party can implement `LanguageModelBackend` outside the package.
2. **`Sendable`-only, no actor isolation in the protocol.** Backends choose their own concurrency model. The CoreML backend uses an internal actor to serialize ANE calls (per doc comment line 11); the Apple backend uses `@unchecked Sendable` because Apple's `FoundationModels.SystemLanguageModel` already handles its own thread-safety.
3. **Streaming via `AsyncThrowingStream`, not an `AsyncSequence` associated type.** Concrete return type. This dodges all the existential / opaque-type pain you get with `some AsyncSequence`.
4. **Multimodal is bolted on with default implementations** (lines 88-112): the protocol declares both text-only `generate(transcript:options:schema:tools:)` and multimodal `generate(transcript:attachments:options:schema:tools:)`, and the latter has a default impl that **drops the attachments and calls the text-only one**. So adding a vision-capable backend is purely additive — text backends compile unchanged.
5. **Backend dispatch is runtime, not compile-time.** The core module *has no notion* of "Apple vs CoreML vs MLX." It just calls `model.backend.generate(...)`. The host app picks the backend at startup (often with a runtime `if AppleFoundationModel.isAvailable { … }` branch — see README "30-second value prop").

The iOS-26-vs-older split is handled entirely inside the Apple backend file with `#if canImport(FoundationModels)` + `@available` (`AppleFoundationModelBackend.swift:26-34, 132-133`). On iOS 18 the whole class simply doesn't exist; on iOS 26 it does and `AppleFoundationModel.load()` works.

**Active backend pointer lives on `SystemLanguageModel`, not on each session** (`SystemLanguageModel.swift:25-77`). It's a `public final class @unchecked Sendable` with a process-wide mutable `static var default: SystemLanguageModel` guarded by `NSLock`. A pre-installed `PlaceholderBackend` (lines 128-152) throws `.modelNotReady` until the host app installs a real one. Sessions snapshot the backend at construction time — re-setting `.default` later only affects *new* sessions, not in-flight ones.

**Hot-swap is tear-down-and-replace.** There's no `swapBackend(_:)` on an existing session. To switch models you build a new `SystemLanguageModel(backend:)` and assign it. State (the `Transcript`) lives on the session, not the backend, so swap doesn't drop history — but a session that exists is bonded to one backend for its lifetime.

**Error propagation:** every backend error funnels through `GenerationError` (`Sources/PrivateFoundationModels/GenerationError.swift`). Apple-specific errors get translated at the boundary — see `AppleFoundationModelBackend.swift:196-205` where `FoundationModels.LanguageModelSession.ToolCallError` is unwrapped one level so callers see the user's tool error directly, matching what CoreML / MLX surface.

## Public API shape

**Drop-in source compatibility with Apple's `FoundationModels` is *literal* — same type names at the same call sites.** Consumer's first line of code, from `README.md`:

```swift
let session = LanguageModelSession(instructions: Instructions("Be brief."))
print(try await session.respond(to: "Capital of France?").content)
```

That code compiles **byte-identically** against either `import PrivateFoundationModels` or `import FoundationModels`. The package goes to real effort to preserve this: `AppleParity.swift:11-15` even re-exports `Response`, `ResponseStream`, and `GenerationError` as typealiases nested inside `LanguageModelSession` so callers can write either `Response<MyType>` or `LanguageModelSession.Response<MyType>` — both compile because Apple's framework nests them. A dedicated executable target `PFMPortability` exists *purely* to compile-test source compatibility: same source files with only the `import` line swapped.

Major public surface (all in `Sources/PrivateFoundationModels/`):
- `LanguageModelSession`, `LanguageModelBackend`, `SystemLanguageModel`
- `Transcript` (`Transcript.Entry` with `kind` ∈ `.instructions/.prompt/.response/.toolCall/.toolOutput`)
- `Instructions`, `Prompt`, `PromptBuilder`, `InstructionsBuilder`
- `Generable` (with `@Generable` / `@Guide` macros), `GenerationSchema`, `GenerationOptions`, `SamplingMode`
- `Tool`, `AnyTool`, `ToolCall`, `Guardrails`
- `Response<T>`, `ResponseStream<T>`, `GenerationError`
- `EmbeddingBackend` — separate protocol, separate slot (`SystemLanguageModel.defaultEmbedder`)

## Pattern transfer to Iris's `Detector` protocol

This is almost a perfect mapping. Iris's `Detector` is exactly PFM's `LanguageModelBackend`.

| PFM | Iris equivalent |
|---|---|
| `LanguageModelBackend: Sendable` | `Detector: Sendable` |
| `SystemLanguageModel(backend:)` wrapper class with mutable `static var default` | Detector held by whichever view/pipeline owns the session; or a `DetectorCache` slot |
| `BackendGeneration` (result type) | `[Detection]` |
| `BackendDelta` (stream emission) | streaming `Detection` updates per frame |
| `prewarm()` async on the protocol | same, hooks ANE / Vision warmup |
| Default-impl multimodal overload that drops attachments | Default-impl stateful overload that drops prior-frame context |
| `availability: Availability` (enum with `.deviceNotEligible / .modelNotReady / .custom`) | Same pattern for "model not loaded / Foundation Models not enabled / Vision req unsupported" |
| `modelIdentifier: String` | Same — useful for telemetry and the dataset sidecar |
| `tokenCount(_:) -> Int?` (default `nil`) | `metrics(for frame:) -> DetectorMetrics?` (optional, default `nil`) — same shape: backend-specific introspection that not every backend can answer |

**Concrete suggestion for Iris's `Detector`:**

```swift
public protocol Detector: Sendable {
    var availability: Detector.Availability { get }
    var modelIdentifier: String { get }
    func prewarm() async
    func detect(in frame: Frame) async throws -> [Detection]
    // Streaming variant — for trajectory / temporal detectors that emit
    // multiple updates per frame, or sub-frame VLM token streams later.
    func detectStream(in frame: Frame) -> AsyncThrowingStream<DetectionDelta, Error>
}
```

With multimodal/captioning bolted on the *same* way PFM did images — additional method, default impl that drops the new input and calls the simpler one. So a `Captioner`-style method (`caption(_:) -> String`) could live on the same `Detector` protocol as a default-`nil` method, and only VLM backends override it.

**Two stylistic borrows worth taking:**

- **Concrete `AsyncThrowingStream`, not `some AsyncSequence`.** PFM didn't bother with the existential dance and the API is cleaner for it.
- **Default protocol implementations as the "additive feature" mechanism.** Don't version the protocol — keep adding methods with sensible defaults so existing conformers keep compiling.

**One borrow worth declining:** PFM's process-wide mutable `SystemLanguageModel.default` is convenient for a CLI/SDK that's typically used singleton-style, but Iris is a SwiftUI library where view ownership is the natural lifetime boundary. The `DetectorCache` should be injected (via `.environment` or a session object), not a global. PFM-style "snapshot at construction" semantics still apply.

## Opinions on Iris's still-open questions

**Q6 (Foundation Models scope: Detector backend vs separate Captioner vs both)** — *the question PFM speaks to most directly.* PFM's answer is unambiguous and well-reasoned: **separate protocols when the I/O shapes don't overlap** (`EmbeddingBackend.swift:9-13` literally says "Embeddings live on a separate protocol because the input / output shapes don't overlap and most backends either generate text **or** embed text, not both"). Same `SystemLanguageModel` shell holds both slots (`.default` and `.defaultEmbedder`), but the protocols are separate.

Applying that to Iris: **detection (image → `[Detection]`) and captioning (image → text) have non-overlapping output shapes.** Most detectors emit detections; FM-based captioners emit text. A few backends might do both (Qwen3-VL-style VLMs), but they conform to *both* protocols, not to one merged super-protocol.

**Recommendation:** Iris should have two protocols — `Detector` and `Captioner` — that compose, not a single mega-protocol. A Foundation-Models backend would be a `Captioner`, not a `Detector`. If a future VLM needs to do both, it conforms to both. PFM's `SystemLanguageModel` / `defaultEmbedder` split is the prior art.

**Q4 (Hot-swap: tear down vs swap detector instance).** PFM's answer: **tear down and replace.** Sessions bond to a backend at construction; you build a new session to switch models. `Detector` can be either value or reference type — what matters is that the owner replaces the instance rather than mutating it. PFM uses reference types for backends (final classes, often `@unchecked Sendable`) because they wrap mutable Apple/MLX session objects, but the public protocol doesn't *require* reference semantics.

**DetectorCache ownership.** PFM's cache layer is implicit (per-backend, e.g. CoreML downloads weights to `~/Library/Application Support/PrivateFoundationModels/<repo-basename>`). The *runtime* "which model is loaded" lives in `SystemLanguageModel.default` as a process-wide singleton with `NSLock` synchronization. Iris probably wants something less global: an injected `DetectorCache` per pipeline/session, with the same "snapshot at construction, replace to switch" pattern.

**Stateful detectors (`VNDetectTrajectoriesRequest`).** PFM's analog: the CoreML backend "holds a single ANE-loaded `MLModel` and serializes requests with an internal actor" (`LanguageModelBackend.swift:9-11`). State is **inside the backend conformer**, hidden from the protocol — the protocol just says `func generate(...) async throws`, and concurrency control is the conformer's problem. For Iris this maps to: `VNDetectTrajectoriesRequest`'s cross-frame state lives inside the `TrajectoryDetector` conformer (likely as an `actor` instance var), not in the `Detector` protocol or in the caller. The protocol stays stateless-looking.

## Verdict

**Study then diverge.** Iris isn't building an LLM SDK — but PFM's protocol shape, additive-multimodal mechanism, separate-protocol-for-different-IO-shapes principle, and concrete `AsyncThrowingStream` choice are directly transferable. Lift the pattern, not the code.

Probably don't depend on PFM as an actual Iris dependency for an FM-based `Captioner`: PFM is large (multiple HTTP servers, benchmarks, MLX dep, swift-syntax dep) for what Iris would need, and the API value is conceptual — Apple's own `FoundationModels` works fine at the `Captioner` level if Iris's deployment target is iOS 26.

## Notes & loose ends

- **Macro target (`PFMMacros`) is included for `@Generable` / `@Guide`.** Pulls in `swift-syntax` (600.0.0). Iris probably doesn't want a macro target for its own scope but worth knowing the option exists for declarative `Detection` typing later.
- **Concurrent-request guard:** `LanguageModelSession.swift:642-656` uses `Mutex<Storage>` (from Swift 6 `Synchronization`) to enforce one-in-flight-request-per-session, throwing `.concurrentRequests` on overlap. Iris detectors will likely want similar protection at the per-frame level — a `Detector` instance probably shouldn't accept overlapping `detect(...)` calls on the same frame stream.
- **Apple-side tool-loop opacity:** `AppleFoundationModelBackend.swift:340-348` calls out that Apple's `LanguageModelSession` runs the tool loop internally and *only emits the result*, so PFM has to walk Apple's post-call transcript to extract intermediate `.toolCall` / `.toolOutput` entries (`extractToolDelta`, lines 216-252). Analog for Iris: any FM-backed `Captioner` would similarly need to surface intermediate state via post-call introspection if those events matter. Most likely they don't, for captioning.
- **No `@MainActor` anywhere in the public API.** Pure `Sendable`. Good model — keeps the API free of UI-framework coupling.
- **`AppleParity.swift` typealiases are clever.** Re-exporting top-level types into nested namespaces purely for source compatibility is a pattern Iris could borrow if it ever wants to mirror an Apple API shape.
