# PlaybackDetectionCoordinator — own the playback detection-session orchestration

<!-- Working plan. Lifetime ~ this feature; LOG.md keeps the trail. Status vocab per WORKFLOW.md §"Status trees". -->
_Defined · 2026-05-27_ · **📋 P1 ready · P2–P3 📋 · P4 🗓 deferred**

## Scope / intent

Both demo `ContentView`s ([`Apps/IrisDemo-macOS/ContentView.swift`](../../Apps/IrisDemo-macOS/ContentView.swift),
[`Apps/IrisDemo-iOS/ContentView.swift`](../../Apps/IrisDemo-iOS/ContentView.swift))
duplicate ~200 lines of playback detection-session glue verbatim: the
`buildSessionAndStartDetection` / `swapDetector` / `swapToExternal` / `teardown`
dance — own the detect loop, hold the `ResultStore` + `DetectionMetrics`, build
the `ActiveDetectorSession`, wire the `onDetectorTierChange → seek` pause-emit
hook, and sequence the cancel → drain → respawn lifecycle. This is the bloat the
2026-05-27 boundary exploration located (player controls are already cleanly in
the library; session orchestration is not). Extract it into one
`@MainActor @Observable` **`PlaybackDetectionCoordinator`** in
`Sources/Iris/Playback/` — a library class the demos *use* rather than
*re-implement*, modeled on the proven `PlaybackController` stack. The demos keep
only genuinely app-specific concerns (file picking, sandbox scope, MRU, the
detector catalog + custom-model UI, layout). Placement is **decided**
([`DECISIONS.md`](../DECISIONS.md), 2026-05-27); the deep case lives in the
exploration
[`RECOMMENDATIONS.md`](../../explorations/2026-05-27-demo-library-boundary/RECOMMENDATIONS.md)
and [`SYNTHESIS.md`](../../explorations/2026-05-27-demo-library-boundary/SYNTHESIS.md).

## API sketch (grounded in the real source types)

```swift
// Sources/Iris/Playback/PlaybackDetectionCoordinator.swift
@MainActor
@Observable
public final class PlaybackDetectionCoordinator {

    // —— Outputs the demo binds its library views to ——
    public let resultStore: ResultStore                       // → DetectionLayer(store:) + DetectionInspector(store:)
    public let metrics: DetectionMetrics                      // → DetectionMetricsView(metrics:)
    public private(set) var controller: PlaybackController?   // → Scrubber(model:) + PlaybackView(source: controller.source)
    public private(set) var session: ActiveDetectorSession?   // → .router for DetectionLayer(tuning:), .settingsView for the tuning sheet

    public init(resultStore: ResultStore = .init(),
                metrics: DetectionMetrics = .init())

    // —— Intent 1: a new video ——
    // Demo builds the PlaybackSource (it holds the security scope) and hands it in.
    public func setSource(_ source: PlaybackSource,
                          detector entry: DetectorCatalogEntry) async

    // —— Intent 2: swap the detector, keep the source ——
    public func selectDetector(_ entry: DetectorCatalogEntry) async

    // —— Teardown (cancel → drain → invalidate); caller releases scope after ——
    public func teardown() async
}
```

**Real-type grounding (verified against `Sources/Iris/` + both demos):**

- `ResultStore` is a `@MainActor @Observable public final class` conforming to
  `DetectionCache` — so it satisfies `DetectorCatalogEntry.makeSession`'s
  `(any DetectionCache) -> ActiveDetectorSession` factory directly.
- `DetectionMetrics` is `@MainActor @Observable public final class`.
- `PlaybackController(source:)` exposes `.source: PlaybackSource`,
  `.currentTime: CMTime`, `.togglePlay()`, `.seek(to:)`, `.presentationSize`;
  it conforms to `ScrubberModel`, so `Scrubber(model: coordinator.controller)`
  is the demo's one-liner.
- `ActiveDetectorSession` (in [`Sources/Iris/Tuning/DetectorCatalog.swift`](../../Sources/Iris/Tuning/DetectorCatalog.swift))
  is a `@MainActor struct` with `router: any TuningRouter` and
  `settingsView: AnyView`. `TuningRouter` carries `currentDetector`,
  `transform`, and the settable `onDetectorTierChange: (@Sendable @MainActor () -> Void)?`.
- A session is built via `entry.makeSession(resultStore)` — `DetectorCatalogEntry`
  (`@MainActor struct`, `Identifiable`) has
  `makeSession: @MainActor (any DetectionCache) -> ActiveDetectorSession`, plus the
  two static factories `make<D: TunableDetector>(id:displayName:detector:)` and
  `make(id:displayName:detector:)` (plain `Detector` → `PassthroughRouter` + `EmptyView`).
- The detect loop runs `pipeline.detect(in: frame, cache: store, tuning: router)`
  over `source.frames` (`DetectorPipeline([])`, empty array — the router's
  `currentDetector` is what runs, per the hot-swap contract).

## What the coordinator owns (moves out of `ContentView`)

1. **The detect loop + its lifecycle** — `for await frame in source.frames { pipeline.detect(in:cache:tuning:) }`,
   including the cancel → **`await detectionTask?.value` drain** → respawn
   sequence the 2026-05-26 bugfix added (commit `f4a6284`; the single-consumer
   `AsyncStream` race). One place, tested once.
2. **Cache + metrics** — constructs/holds `ResultStore` and `DetectionMetrics`;
   `resultStore.invalidateAll()` + `metrics.reset()` at the right moments
   (detector swap, new source).
3. **Session construction** — calls `entry.makeSession(resultStore)`, holds the
   resulting `ActiveDetectorSession` and its `router`.
4. **The pause-emit hook** — self-wires
   `session.router.onDetectorTierChange = { [controller] in Task { try? await controller.source.seek(to: controller.currentTime) } }`.
   Demo-side today only because the demo owns the loop; once the coordinator owns
   both, it wires itself.
5. **Playback lifecycle** — creates and owns the `PlaybackController` for the
   handed-in source; tears down in the correct order (cancel task → drain →
   `source.invalidate()`), returning so the demo can sequence the scope release
   after.

## What stays in the demo (the outer layer)

- **Screen composition & chrome** — `NavigationSplitView` / tab shape, the tuning
  inspector presentation, the metrics HUD layout, the gear/inspector toggle,
  keyboard shortcuts, window/scene setup.
- **Source selection UX** — `.fileImporter` / `DocumentPicker`,
  **security-scoped bookmarks** (a sandbox-entitlement concern: the demo acquires
  the scope, builds `PlaybackSource(url:)`, hands the *source* to the coordinator,
  and releases the scope only after `await coordinator.teardown()` returns), `RecentVideos`
  (MRU), the bundled-fixture choice (iOS).
- **Detector catalog ownership + custom-model UX** — *which* entries exist
  (`DemoCatalog.detectors(store:)`), the picker UI, the "Load model…" importer,
  `DemoModelStore` (prewarm + picked detector + `.modelNotReady` dimming). The
  demo resolves a picker selection into a `DetectorCatalogEntry` (loading a custom
  model first if needed), then calls `coordinator.selectDetector(entry)`.
- **Wiring library views to coordinator outputs** —
  `PlaybackView(source: coordinator.controller?.source)`,
  `Scrubber(model: coordinator.controller)`,
  `DetectionLayer(store: coordinator.resultStore, …, tuning: coordinator.session?.router)`,
  hosting `coordinator.session?.settingsView`, reading `coordinator.metrics`.

Net: both `ContentView`s shrink by ~200 lines each and stop duplicating
iOS↔macOS.

## Phases

### P1 — Land the coordinator in `Playback/` + tests  📋

Build `Sources/Iris/Playback/PlaybackDetectionCoordinator.swift` as the
`@MainActor @Observable` class above. Move the four owned responsibilities off
the demos into it (loop + lifecycle, cache/metrics, session construction,
self-wired pause-emit hook). No demo changes yet; `swift test` + both demo
schemes stay green (they keep their existing inline glue until P2/P3).

**Tests — close the accepted gap** ([`QUESTIONS.md`](../QUESTIONS.md),
`[open 2026-05-26]` "No regression test for the playback detector-swap path").
The coordinator is now a library type, so it's testable under `swift test`:
drive it with a manual/mock source and **two distinct fixture detectors**, then
assert the *new* detector's output is what lands after a mid-stream swap. The
test seam already exists in the package:

- `PlaybackSource(url:driver:)` accepts a `ManualTickDriver` (`fire()` advances
  one tick deterministically) — or `MockSource` (`Sources/Iris/MockSource.swift`)
  for a fixed `Frame` sequence with no AVF.
- `MockDetector` (`Sources/Iris/Detection/MockDetector.swift`) — two instances
  with distinct outputs as the "old" vs. "new" detector, registered as
  `DetectorCatalogEntry.make(…)` entries.

The **swap regression test**: start the loop on detector A, drive a frame,
`selectDetector(B)`, drive (or re-emit) a frame, assert the cached/emitted
detections are B's — the cancel → **drain** → respawn ordering is what makes B
the sole consumer of the re-emitted frame (the bug commit `f4a6284` fixed, now
guarded). Also cover: `setSource` resets metrics + cache; `teardown` returns
only after the source is invalidated (the scope-ordering contract, below).

### P2 — Rewire the macOS demo  📋

Replace [`Apps/IrisDemo-macOS/ContentView.swift`](../../Apps/IrisDemo-macOS/ContentView.swift)'s
`@State` for `controller` / `resultStore` / `detectionTask` / `metrics` /
`session` with one `@State private var coordinator = PlaybackDetectionCoordinator()`.
Delete the duplicated `buildSessionAndStartDetection` / `swapDetector` and the
loop/hook/drain code inside `swapToExternal` / `teardown`; the demo's
`swapToExternal` becomes: acquire scope → `PlaybackSource(url:)` →
`await coordinator.setSource(source, detector: entry)` → `controller.togglePlay()`;
its picker `.onChange` becomes `await coordinator.selectDetector(entry)`; its
`teardown` becomes `await coordinator.teardown()` *then* release scope. Bind the
views to coordinator outputs (the "stays in the demo" list). Verify by hand —
swap detector mid-video, tune a `.detector`-tier knob while paused, scrub, open a
new video — plus `xcodebuild` for the macOS scheme.

### P3 — Rewire the iOS demo identically  📋

Same rewrite on [`Apps/IrisDemo-iOS/ContentView.swift`](../../Apps/IrisDemo-iOS/ContentView.swift),
which carries a byte-identical copy of the glue (`buildSessionAndStartDetection`
/ `swapDetector` / `swapToExternal` / `teardown`), plus its bundled-fixture
`loadFixture` path (still demo-owned — it just builds a `PlaybackSource` from the
bundled URL and calls `setSource`). Delete its glue; verify by hand on the
Playback tab + `xcodebuild` for the iOS scheme. After P3 the only
playback-detection orchestration left is in the one library type.

### P4 — External-controls polish + source-agnostic core  🗓 deferred

Optional, later, and **off this feature's critical path**:

- **External-controls ergonomics** — splitting `ScrubberModel` into intent vs.
  state halves for remote/intent-only controllers (the seam already exists —
  `PlaybackController` satisfies `ScrubberModel`; external controls drive
  `coordinator.controller` with no library change). Orthogonal layer.
- **Source-agnostic core (`DetectionRunner`)** — lift the loop + cache + metrics
  core into a `Detection/`-side runner the coordinator composes, *if/when* a
  capture-side detection consumer lands. **Deliberately not pre-split** (see
  Opens) — splitting later is non-breaking per the single-target doctrine.

## Opens / risks

- **❓ Source-agnostic decomposition (open question, do not pre-split).** The
  coordinator is playback-coupled — it needs a `PlaybackController` + `seek` for
  the pause-emit hook, so `Sources/Iris/Playback/` is the right home (decided,
  [`DECISIONS.md`](../DECISIONS.md) 2026-05-27). But the detect-loop + cache +
  metrics core is genuinely source-agnostic, and a future capture-side detection
  consumer would want it. Recommendation per the exploration: build the concrete
  `PlaybackDetectionCoordinator` in `Playback/` now; extract a `Detection/`-side
  `DetectionRunner` only when capture-side detection actually lands. Per the
  repo's "splitting later is non-breaking" doctrine, **don't pre-split**. The
  decomposition call stays open until that consumer materializes — see
  [`QUESTIONS.md`](../QUESTIONS.md) and the
  [`RECOMMENDATIONS.md`](../../explorations/2026-05-27-demo-library-boundary/RECOMMENDATIONS.md)
  caveat.
- **🚩 Non-tunable detectors.** The plain-`Detector` factory
  `DetectorCatalogEntry.make(id:displayName:detector:)` (path-A Core ML) yields a
  `PassthroughRouter` + `EmptyView` settings view. The coordinator must treat
  `session.settingsView` as possibly empty and `router.onDetectorTierChange` as a
  no-op consumer (`PassthroughRouter` never fires it) — no special-casing, just
  don't assume tunability.
- **🚩 Sandbox-scope ordering contract.** `teardown()` (and `setSource`'s
  internal teardown of the prior source) is `async` and must complete the source
  `invalidate()` **before** the demo releases the security-scoped resource — AVF
  must not read from a URL whose scope was already dropped. The coordinator
  *returns* from `teardown()` / `setSource()` so the demo can sequence
  `stopAccessingSecurityScopedResource()` strictly after the await. Document this
  on the type; the P1 test asserts the return-after-invalidate ordering.
- **🚩 Touches two app targets.** This is a real chunk of work spanning
  `Sources/Iris/Playback/` plus both demo `ContentView`s. P2 and P3 each carry a
  manual-smoke + `xcodebuild` gate; the byte-identical glue across the two demos
  is exactly why centralizing it is worth the cross-target reach.

## Links

- Exploration: [`explorations/2026-05-27-demo-library-boundary/RECOMMENDATIONS.md`](../../explorations/2026-05-27-demo-library-boundary/RECOMMENDATIONS.md)
  · [`SYNTHESIS.md`](../../explorations/2026-05-27-demo-library-boundary/SYNTHESIS.md)
- Decision (placement): [`DECISIONS.md`](../DECISIONS.md) (2026-05-27)
- Test gap this closes: [`QUESTIONS.md`](../QUESTIONS.md) (`[open 2026-05-26]` detector-swap regression)
- Prior bugfix this guards: commit `f4a6284` (serialize detection-task teardown on mid-stream swap)
