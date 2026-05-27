# Recommendations: extract a `PlaybackDetectionCoordinator`

_Follows [`SYNTHESIS.md`](./SYNTHESIS.md). The analysis found player controls
already cleanly in the library and detection-session orchestration almost
entirely duplicated demo glue. This is the proposal to fix the latter._

## Recommendation

Introduce one library type — a `@MainActor @Observable`
**`PlaybackDetectionCoordinator`** — that owns the detection-session machinery
the two demos currently duplicate. Model it on the player-controls stack that
already works: a class the demo *uses*, not logic the demo *re-implements*. The
demo keeps only genuinely app-specific concerns (file picking, sandbox scope,
which detectors exist, layout).

### API sketch (working names, grounded in existing types)

```swift
@MainActor
@Observable
public final class PlaybackDetectionCoordinator {

    // —— Outputs the demo binds its library views to ——
    public let resultStore: ResultStore                 // → DetectionLayer(store:)
    public let metrics: DetectionMetrics                // → metrics HUD
    public private(set) var controller: PlaybackController?   // → Scrubber(model:) + PlaybackView(source:)
    public private(set) var session: ActiveDetectorSession?  // → .router for overlay, .settingsView for the tuning sheet

    public init(resultStore: ResultStore = .init(),
                metrics: DetectionMetrics = .init())

    // —— Intent 1: a new video ——
    // Demo builds the PlaybackSource (it holds the sandbox scope) and hands it in.
    public func setSource(_ source: PlaybackSource,
                          detector entry: DetectorCatalogEntry) async

    // —— Intent 2: swap the detector, keep the source ——
    public func selectDetector(_ entry: DetectorCatalogEntry) async

    // —— Teardown (cancel → drain → invalidate); caller releases scope after ——
    public func teardown() async
}
```

### What the coordinator owns (moves out of `ContentView`)

1. **The detect loop + its lifecycle** — `for await frame in source.frames { pipeline.detect(in:cache:tuning:) }`, including the cancel → **`await task.value` drain** → respawn sequence that the 2026-05-26 bugfix added. One place, tested once.
2. **Cache + metrics** — constructs/holds `ResultStore` and `DetectionMetrics`; invalidates the cache and resets metrics at the right moments (detector swap, new source).
3. **Session construction** — calls `entry.makeSession(resultStore)`, holds the resulting `ActiveDetectorSession` and its `router`.
4. **The pause-emit hook** — self-wires `session.router.onDetectorTierChange = { [controller] in controller?.seek(to: controller.currentTime) }`. This is the one piece that was demo-side *only because* the demo owned the loop; once the coordinator owns both, it wires itself.
5. **Playback lifecycle** — creates and owns the `PlaybackController` for the handed-in source; tears down in the correct order.

### What stays in the demo (the outer layer, after the refactor)

This is the direct answer to "what still lives in the demo layer":

- **Screen composition & chrome** — `NavigationSplitView`, the tuning sheet presentation, the metrics HUD layout, inspector toggle, keyboard shortcuts, window/scene setup.
- **Source selection UX** — `.fileImporter` / `DocumentPicker`, **security-scoped bookmarks** (the sandbox scope is an app entitlement concern — the demo acquires it, builds `PlaybackSource(url:)`, hands the source to the coordinator, and releases the scope after `await coordinator.teardown()`/replace), MRU / `RecentVideos`, the bundled fixture choice.
- **Detector catalog ownership + custom-model UX** — *which* entries exist, the picker UI, the "Load model…" importer, `DemoModelStore` (prewarm + picked detector + availability dimming). The demo resolves a picker selection into a `DetectorCatalogEntry` (loading a custom model first if needed), then calls `coordinator.selectDetector(entry)`.
- **Wiring library views to coordinator outputs** — `PlaybackView(source:)`, `Scrubber(model: coordinator.controller)`, `DetectionLayer(store: coordinator.resultStore, tuning: coordinator.session?.router)`, hosting `coordinator.session?.settingsView`, reading `coordinator.metrics`.

Net: both `ContentView`s shrink by ~200 lines each and stop duplicating iOS↔macOS.

### Is the user's mental model right?

Mostly yes, with one refinement:

- **"Select a different URL → pass it to the coordinator"** — *almost.* The demo passes a **`PlaybackSource`**, not a raw URL, because the demo (not the library) holds the security-scoped bookmark for sandboxed file access. That's the only adjustment; everything downstream (build controller, build session, start the loop, clear cache, reset metrics) happens under the covers. (A `setSource(url:)` convenience could exist for non-sandboxed callers, but the demo uses the source form.)
- **"Switch the detector → goes straight into the coordinator, which does everything"** — *yes,* with the split that the demo resolves *which* entry (incl. loading a custom model via its file-picker UI), then hands the resolved `DetectorCatalogEntry` to `coordinator.selectDetector(_:)`. The coordinator then does the invalidate + rebuild + drain + respawn + pause-emit — all the mechanics. The demo never touches the task, the cache, or the hook again.

## Why

- **Removes duplication & a whole bug class.** The orchestration is currently copy-pasted across two files; the swap race lived there precisely because it was demo glue. Centralizing it fixes-once, tests-once.
- **Closes the accepted test gap** ([`plans/QUESTIONS.md`](../../plans/QUESTIONS.md), 2026-05-27). The coordinator is a `@MainActor @Observable` library type → testable with `MockSource`/`ManualTickDriver` + two fixture detectors: drive frames, `selectDetector`, assert the *new* detector's output lands. The swap regression becomes a real fixture test.
- **Delivers Iris's actual promise.** "Camera/playback + detect + tune, scaffolding done" — right now a consumer would re-derive 200 lines of loop/cache/hook wiring. The coordinator hands them the loop.
- **Composes with the player-controls work.** The coordinator exposes `controller: PlaybackController` (a `ScrubberModel`), so the planned optional external controls drive the same object — no conflict, they're orthogonal layers. Do the coordinator first or in parallel; external controls plug into its `controller`.
- **Mirrors a proven pattern.** It's the same shape as the already-clean `PlaybackController` (a `@MainActor @Observable` library class wrapping messy async lifecycle behind a SwiftUI-friendly surface).

## Migration plan

1. **Land the coordinator in the library + tests** (incl. the swap regression). No demo changes yet; build green.
2. **Rewire the macOS demo** to use it; delete the duplicated `buildSessionAndStartDetection` / `swapDetector` / session `@State`. Verify by hand (swap mid-video; tune; scrub) + `xcodebuild`.
3. **Rewire the iOS demo** identically; delete its glue.
4. **(Optional, later)** external-controls polish (split `ScrubberModel` intent vs. state) and the source-agnostic-core extraction (below).

## Caveats / open questions

- **Where does it live, and how source-agnostic?** It's playback-coupled (needs a `PlaybackController` and `seek` for the pause-emit hook), so `Sources/Iris/Playback/` is the natural home. But the detect-loop + cache + metrics core is genuinely source-agnostic and a future **capture-side** detection consumer would want it. Recommend: build the concrete `PlaybackDetectionCoordinator` in `Playback/` now; if/when capture-side detection lands, lift the loop core into a `Detection/`-side `DetectionRunner` that the coordinator composes. Per the repo's "splitting later is non-breaking" doctrine, don't pre-split. **→ land this placement/decomposition call in [`plans/QUESTIONS.md`](../../plans/QUESTIONS.md) before building, or settle it in [`plans/DECISIONS.md`](../../plans/DECISIONS.md).**
- **Non-tunable detectors.** `DetectorCatalogEntry.make(detector:)` (path-A Core ML) yields a `PassthroughRouter` + `EmptyView` settings view. The coordinator must treat `session.settingsView` as possibly empty and `router.onDetectorTierChange` as a no-op consumer (`PassthroughRouter` never fires it) — no special-casing, just don't assume tunability.
- **Sandbox scope ordering.** The async `teardown()` must complete (source `invalidate()`) before the demo releases the security scope — the coordinator returns from `teardown()`/`setSource()` so the demo can sequence the scope release after. Document this contract.
- **Scope of the refactor.** This is a real chunk of work touching two app targets. Worth its own feature plan (`plans/features/<slug>.md`) if taken on, not a drive-by.
