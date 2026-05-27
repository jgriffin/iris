# Synthesis: the demo/library boundary

_2026-05-27 · traces of four flows (switch video, switch detector, change a
filter, player controls) across `Apps/IrisDemo-{iOS,macOS}/ContentView.swift`
and `Sources/Iris/`. Line numbers are iOS unless noted; the two demos are
near-identical._

## Headline

Iris has **two control subsystems sitting at opposite ends of the
demo/library boundary:**

| Subsystem | State today | Verdict |
| --- | --- | --- |
| **Player controls** (play/pause/seek/step, scrubber) | Fully in the **library** — `ScrubberModel` protocol + `PlaybackController` + generic `Scrubber` view. Demo just writes `Scrubber(model: controller)`. | Already factored. External-controls seam **already exists**. |
| **Detection-session orchestration** (switch video, switch detector, run the detect loop, own the cache + metrics, wire the pause-emit hook) | Almost entirely **demo glue** — ~200 lines duplicated verbatim across both ContentViews. | This is the bloat. The real refactor candidate. |

So the instinct "too much is happening in ContentView" is right, but precisely
located: it's the **session orchestration**, not the player controls. The
player-controls work the user is about to start is the *already-solved* half;
the lesson from it (a protocol + an `@Observable` conformer the library owns) is
exactly the template the session half is missing.

---

## The cast (who owns what, library side)

- **`PlaybackSource`** (`Sources/Iris/Playback/PlaybackSource.swift`) — AVF wrapper. `@unchecked Sendable`, NSLock-guarded (its tick driver fires off-MainActor). Owns the **single-consumer** `frames: AsyncStream<Frame>` (created once in `init`, line 139/236), playback controls (`play/pause/seek/step`), the tick driver, and the seek/step **one-shot frame re-emit** (`emitOneShotFrame`, :427). Not observable by design.
- **`PlaybackController`** (`PlaybackController.swift`) — `@MainActor @Observable` mirror of the source for SwiftUI. Owns the AVF observers: periodic time observer ~30 Hz → `currentTime`; KVO → `duration`, `state`, `presentationSize`. Bridges sync UI intents to async source calls via `Task`. Conforms to `ScrubberModel`.
- **`Scrubber` / `ScrubberModel`** (`Scrubber.swift`, `ScrubberModel.swift`) — generic control UI + its contract. `Scrubber<Model: ScrubberModel>` renders the buttons/slider; `PlaybackController` is the production conformer, `MockScrubberModel` the test double.
- **`DetectorPipeline.detect(in:cache:tuning:)`** (`Detection/DetectorPipeline.swift`) — the per-frame work: cache `fetch` → on miss run `tuning.currentDetector` → write-through `append` → apply `tuning.transform`. The **hot-swap contract** lives here: it reads the detector from the router every frame, so the pipeline's own detector array is empty.
- **`TuningModel` / `TuningRouter`** (`Tuning/TuningModel.swift`) — the tuning spine. `update(key:to:)` → `dispatch()` → `detector.apply(change)` returns a **tier**; the model routes it. `currentDetector`, `transform`, and `onDetectorTierChange` are the three slots the rest of the system reads.
- **`CapabilityTuningView`** (`Tuning/UI/`) — generic derived tuning UI; renders any `TunableDetector`'s knobs from its schema. Library-quality, hosted by the demo's sheet.
- **`DetectorCatalogEntry.makeSession(cache:)`** (`Detection/DetectorCatalog.swift`) — factory: builds a `TuningModel` + settings view, returns a type-erased `ActiveDetectorSession`.
- **`ResultStore`** (cache) / **`DetectionMetrics`** — concrete types the **demo** constructs and owns (`@State`), passed into sessions/pipeline.

---

## Flow 1 — Switch video

**Entry (DEMO):** file importer / MRU tap / first-load → `swapToExternal(url:)` → `startSession(...)`.

**Order:**
1. **DEMO** `teardown()` — cancel detection task, `invalidate()` source, drop security scope, `resultStore.clear()`.
2. **DEMO** acquire security scope on the new URL; register MRU; `metrics.reset()`.
3. **DEMO** `PlaybackSource(url:)` + `PlaybackController(source:)` → `@State`.
4. **LIBRARY** controller `init` wires time observer + KVO.
5. **DEMO** `Task { await buildSessionAndStartDetection(on:); controller.togglePlay() }`.
6. Inside build (**DEMO**): cancel old task → `await detectionTask?.value` (drain) → catalog lookup → `entry.makeSession(resultStore)` (**LIBRARY** factory) → wire `onDetectorTierChange` → spawn the `for await frame in source.frames { pipeline.detect(...) ; record metrics }` loop.

**Caching:** `ResultStore` is **demo-owned** (`@State`, :196). Cleared on teardown. The cache *protocol* and skip-gate semantics are library.

**Boundary read:** ~60% demo. Library gives the parts (source, controller, pipeline, session factory); the demo writes all the *sequencing*. Only security-scope + MRU are genuinely app-specific. The build-session-and-run-loop dance is generic.

---

## Flow 2 — Switch detector

**Entry (DEMO):** picker `.onChange(of: selectedDetectorID)` → `swapDetector()`.

**Order:**
1. **DEMO** `resultStore.invalidateAll()` (old detections are from a different detector).
2. **DEMO** `metrics.reset()`.
3. **DEMO** `Task { await buildSessionAndStartDetection(on:); await source.seek(to: currentTime) }` — same build path as Flow 1 (cancel → **drain** → new session/router → new loop), then a **pause-emit seek** so a paused player re-runs detection under the new detector immediately.

**Caching:** explicit demo `invalidateAll()` (defensive; the new session starts with the same shared store).

**Boundary read:** ~70% demo. Library role is narrow (`makeSession`). All the task lifecycle (cancel/drain/respawn) + the pause-emit re-emit timing is demo glue. **This is where the single-consumer-stream bug lived** (fixed 2026-05-26 by `await detectionTask?.value`); it lives in demo code precisely *because* the orchestration is in the demo.

---

## Flow 3 — Change a detector filter / threshold

The tuning system is the **best-factored of the three** — almost all library. The
key concept is the **three-tier** classification (`Tuning/DetectorSettings.swift`
`ChangeTier`):

- **`.view`** — re-render only. No detector change, no cache change.
- **`.filter`** — post-hoc output filter. Detector & cache **unchanged**; a `transform` closure is installed and applied read-side.
- **`.detector`** — rebuild the detector instance; **invalidate the cache**; hot-swap.

A knob's schema carries a *worst-case* tier; the detector's `apply(_:)` can
**downgrade per transition/direction** (e.g. raising `minimumAspectRatio`
narrows → `.filter`; lowering widens → needs fresh inference → `.detector`).

**Filter-tier change (e.g. raise quadrature tolerance):**
1. **LIBRARY** slider binding → `model.update(key:to:)` → `dispatch` → `detector.apply` returns `.filter(transform:)`.
2. **LIBRARY** `TuningModel` installs `self.transform`. **No cache touch.**
3. **LIBRARY** next pipeline pass *and* the overlay's 60 Hz tick (`DetectionLayer`) read `tuning.transform` and apply it. **Updates even while paused** — overlay re-projects cached detections; no re-inference, no seek.

**Detector-tier change (e.g. lower aspect ratio):**
1. **LIBRARY** `apply` returns `.detector(rebuilt:)`.
2. **LIBRARY** `TuningModel` (in a `@MainActor Task`): swap `currentDetector`, clear `transform`, `cache?.invalidateAll()`, then fire `onDetectorTierChange`.
3. **DEMO** the hook (wired in `buildSessionAndStartDetection`) does `source.seek(to: currentTime)` → one-shot frame → loop runs the rebuilt detector → fresh cache → overlay draws it.

**Boundary read:** the tier spine (`TuningModel`/`TuningRouter`/`ChangeTier`), the
derived UI (`CapabilityTuningView`), and the cache-invalidate-on-detector-tier
are all **library**. The *only* demo glue is **wiring `onDetectorTierChange` to
`source.seek`** — and that's demo-specific only because the demo owns the loop
and the source. If a library orchestrator owned the loop, the hook would wire
itself.

---

## Flow 4 — Player controls

**Already a clean library stack.** The demo writes exactly one line:
`Scrubber(model: controller)`.

**Press → reaction order (play/pause):**
1. **LIBRARY** `Scrubber` button → `model.togglePlay()` (sync, MainActor).
2. **LIBRARY** `PlaybackController.togglePlay()` → `Task { await source.play()/pause(); state = source.state }`.
3. **LIBRARY** `PlaybackSource.play()` starts the tick driver + `player.play()`.
4. Tick driver → `tick()` → `copyPixelBuffer` → `continuation.yield(frame)`.
5. **DEMO** detect loop consumes the frame (only demo touchpoint).
6. **LIBRARY** periodic time observer (~30 Hz) updates `currentTime`/`state` on MainActor.
7. SwiftUI sees `@Observable` change → scrubber re-renders.

Seek/step are identical except they call `source.seek/step`, which **reset the
monotonicity guard and emit a one-shot frame** — the same primitive the
pause-emit hook reuses. Paused: the one-shot frame is the *only* emission, which
is what makes a scrub update the overlay while paused.

**Source of truth / "how do we know we got it right":** `PlaybackSource` state
(AVF) is truth; `PlaybackController` is a mirror kept in sync two ways —
explicit refresh after each intent (`await source.X(); state = source.state`)
and continuous refresh on every time-observer tick. The UI only ever reads the
mirror.

**External-controls seam — already present.** `ScrubberModel` is the public
intent+state contract; `PlaybackController` satisfies it. An external control
surface either (a) drives the existing `PlaybackController` (`togglePlay/seek/
step`) and observes its properties, or (b) implements `ScrubberModel` itself.
**No library changes needed** to add optional external controls — the only thing
worth adding is ergonomic: e.g. splitting `ScrubberModel` into intent vs.
state-observation halves if remote controllers want intent-only, and possibly a
documented "bring your own controls" entry point. The plumbing is done.

---

## The convergence

The detection-session orchestration (Flows 1–2, and the demo half of Flow 3) is
the **duplicated, untested, bug-prone** glue. It is also exactly the seam whose
absence left the 2026-05-26 swap bug untestable (no coordinator to test against).

A library **`PlaybackDetectionCoordinator`** (working name) would own:
- the `for await frame` detect loop + its lifecycle (cancel → drain → respawn),
- the `ResultStore` + `DetectionMetrics` wiring,
- the `onDetectorTierChange → seek` pause-emit hook (self-wired),
- `selectDetector(_:)` / `setSource(_:)` as the two intents,

modeled on the player-controls stack that already works: a `@MainActor
@Observable` class the demo *uses* rather than *re-implements*, with the demo
keeping only genuinely app-specific concerns (security scope, MRU, file picking,
which catalog entries to show, HUD layout). That single extraction would: shrink
both ContentViews by ~200 lines each, de-duplicate iOS/macOS, make the swap path
testable (closing the accepted gap), and give downstream consumers the
"capture/playback + detect + tune" loop for free — the stated point of Iris.

This is a recommendation to discuss, not a decision. Open question: does the
coordinator belong in `Playback/` (it drives a source), `Detection/` (it drives a
detector), or a new seam — and how does it stay source-agnostic so a future
capture-side consumer reuses it. See RECOMMENDATIONS once direction is chosen.
