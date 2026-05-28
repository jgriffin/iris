# PlaybackDetectionCoordinator — own the playback detection-session orchestration

<!-- Working plan. Lifetime ~ this feature; LOG.md keeps the trail. Status vocab per WORKFLOW.md §"Status trees". -->
_Defined · 2026-05-27_ · **✅ P1–P3 done (`51743c7` · `1ea2cd1` · `ad7428d`) · P4 🗓 deferred · 👀 hands-on smoke pending**

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
  `currentDetector` is what runs, per the hot-swap contract). The loop reads the
  **live `session.router` per frame** — a `selectDetector` swap is an **in-place**
  router replacement, so the next frame routes through the new detector with no
  stream re-iteration (the loop is never cancelled/respawned mid-source).

## What the coordinator owns (moves out of `ContentView`)

1. **The detect loop + its lifecycle** — **one loop per source**:
   `for await frame in source.frames { pipeline.detect(in:cache:tuning: session.router) }`.
   A detector swap is handled **in place** — `selectDetector` rebuilds the
   session and the loop reads the **live `session.router` on every frame**, so the
   next frame routes through the new detector with **no stream re-iteration**.
   The cancel → `await detectionTask?.value` drain → **respawn** sequence the
   2026-05-26 bugfix added (commit `f4a6284`) was found **non-functional** while
   building P1: `PlaybackSource.frames` is a single *stored* `AsyncStream`, so
   cancelling its consumer **terminates the stream permanently** — a respawned
   `for await` gets zero frames. (Teardown is different: there the loop is being
   killed for good, so its cancel → drain → `invalidate()` is correct.) One loop,
   one place, tested once.
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

### P1 — Land the coordinator in `Playback/` + tests  ✅ (commit `51743c7`)

Built `Sources/Iris/Playback/PlaybackDetectionCoordinator.swift` as the
`@MainActor @Observable` class above. The four owned responsibilities moved off
the demos into it (loop + lifecycle, cache/metrics, session construction,
self-wired pause-emit hook). **The detect loop runs once per source and swaps the
detector in place** — `selectDetector` rebuilds the session and the live loop
reads `session.router` on the next frame; the loop is **never cancelled and
respawned mid-source** (that approach was found non-functional — see the Finding
below). No demo changes; `swift test` + both demo schemes stay green (they keep
their inline glue until P2/P3). `swift test` **215 pass**, Swift 6
strict-concurrency clean.

> **Finding (2026-05-27).** The 2026-05-26 fix `f4a6284` (cancel → drain →
> respawn) is a **no-op**. `PlaybackSource` exposes a single *stored*
> `AsyncStream` (`_frames` + one `continuation`); cancelling its consuming task
> **terminates the stream permanently**, so a respawned `for await source.frames`
> receives **zero** frames and every later `yield` returns `.terminated`
> (confirmed with an isolated `AsyncStream` repro). There is **no race** — the
> drain serializes nothing load-bearing; the stream is simply dead after cancel.
> The reported "swap does nothing until reload" symptom was therefore **never
> actually fixed** by `f4a6284` (reload only masks it by building a fresh source
> → fresh stream). This is why the coordinator departs from the demos' glue: it
> runs **one loop per source + in-place router swap**, so a `selectDetector` swap
> deterministically routes the next frame through the new detector. P2/P3
> rewiring the demos onto the coordinator will **actually fix the demo swap bug
> for the first time**.

**Tests — closed the accepted gap** ([`QUESTIONS.md`](../QUESTIONS.md),
`[answered 2026-05-27]`). The coordinator is a library type, so it's testable
under `swift test`. [`Tests/IrisTests/Playback/PlaybackDetectionCoordinatorTests.swift`](../../Tests/IrisTests/Playback/PlaybackDetectionCoordinatorTests.swift)
drives two distinct `MockDetector`s (registered as `DetectorCatalogEntry.make(…)`
entries) over a `PlaybackSource(url:driver:)` with a deterministic tick driver,
**swaps mid-stream** via `selectDetector`, and asserts the new detector owns the
**subsequent** frames' cached output. Frames are driven via `source.seek(to:)` to
**distinct timestamps** (the paused same-time re-emit is a headless no-op, so it
can't be relied on to deliver a post-swap frame). Plus: `setSource` resets
metrics + cache; `teardown` returns **only after** the source is invalidated (the
scope-ordering contract, below). The negative half asserts the **correct
end-state** (after the swap, the new detector's output is what lands) rather than
reproducing a race — **there is no race**; the in-place swap is deterministic.

### P2 — Rewire the macOS demo  ✅ (commit `1ea2cd1`, −94 lines, xcodebuild green; smoke pending)

Replace [`Apps/IrisDemo-macOS/ContentView.swift`](../../Apps/IrisDemo-macOS/ContentView.swift)'s
`@State` for `controller` / `resultStore` / `detectionTask` / `metrics` /
`session` with one `@State private var coordinator = PlaybackDetectionCoordinator()`.
Delete the duplicated `buildSessionAndStartDetection` / `swapDetector` and the
loop/hook/drain code inside `swapToExternal` / `teardown`; the demo's
`swapToExternal` becomes: acquire scope → `PlaybackSource(url:)` →
`await coordinator.setSource(source, detector: entry)` → `controller.togglePlay()`;
its picker `.onChange` becomes `await coordinator.selectDetector(entry)`; its
`teardown` becomes `await coordinator.teardown()` *then* release scope. Bind the
views to coordinator outputs (the "stays in the demo" list). This **actually
fixes the demo swap bug for the first time** — the demo's existing respawn glue
(`f4a6284`) is a no-op (single stored `AsyncStream` dies on consumer cancel), so
moving onto the coordinator's single-loop + in-place router swap is what makes a
mid-video swap work without reload; it's not merely centralizing code. Verify by
hand — swap detector mid-video, tune a `.detector`-tier knob while paused, scrub,
open a new video — plus `xcodebuild` for the macOS scheme.

### P3 — Rewire the iOS demo identically  ✅ (commit `ad7428d`, −102 lines, xcodebuild green; smoke pending)

Same rewrite on [`Apps/IrisDemo-iOS/ContentView.swift`](../../Apps/IrisDemo-iOS/ContentView.swift),
which carries a byte-identical copy of the glue (`buildSessionAndStartDetection`
/ `swapDetector` / `swapToExternal` / `teardown`), plus its bundled-fixture
`loadFixture` path (still demo-owned — it just builds a `PlaybackSource` from the
bundled URL and calls `setSource`). Delete its glue; like P2 this **actually
fixes the iOS demo's mid-video swap bug for the first time** (its respawn glue is
the same no-op), not merely centralization. Verify by hand on the Playback tab +
`xcodebuild` for the iOS scheme. After P3 the only playback-detection
orchestration left is in the one library type.

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
- Test gap this closes: [`QUESTIONS.md`](../QUESTIONS.md) (`[answered 2026-05-27]` detector-swap regression)
- Prior "bugfix" this supersedes: commit `f4a6284` (cancel→drain→respawn) — found a **no-op** (single stored `AsyncStream` dies on consumer cancel); see the Finding under P1 and [`LOG.md`](../LOG.md) (2026-05-27)
