# Playback detection cache + seek-frame delivery

**Scope.** Library-side fix to the playback subsystem shipped in [M3](./M3.md). Three composable changes that, together, eliminate the seek-time detection gaps observed during M3 close-out smoke (`macOS playback: detections disappear when seeking backward into already-played regions; reappear when seeking forward back toward where playback last was`). The work also folds in the `[open]` displayTime-divergence item in [`../QUESTIONS.md`](../QUESTIONS.md) — that question becomes answered by the new lookup semantics rather than tracked as a separate concern.

Demo-side ergonomics (iOS file picker, MRU on both targets) is a **separate follow-up phase** — see [`./demo-ergonomics.md`](./demo-ergonomics.md) when opened.

## Diagnostic context (from the 2026-05-22 investigation)

Three stacked bugs produce the symptom:

1. **`ResultStore` is a 30-frame ring buffer** ([`ResultStore.swift:40`](../../Sources/Iris/Overlay/ResultStore.swift)). At 30 fps that's ~1s of coverage; any backward seek further than ~1s of recent play history lands in an evicted region. `clear()` carries a docstring referencing a non-existent `PlaybackSession.willSeek` — it's never called.
2. **`DetectorPipeline` does not dedupe by `Frame.timestamp`** ([`DetectorPipeline.swift:53–70`](../../Sources/Iris/Detection/DetectorPipeline.swift)). Every frame runs through every detector, no "have we seen this timestamp" gate. Re-visiting an already-detected timestamp is wasted work — and, more importantly, the detector doesn't *know* a re-visit happened.
3. **Seek-emitted one-shot frames can be silently dropped by `.bufferingNewest(1)`.** Phase 2 of M3 added `emitOneShotFrame()` ([`PlaybackSource.swift:277–301`](../../Sources/Iris/Playback/PlaybackSource.swift)) so `seek` / `step` produce a fresh `Frame` for the new asset time. But if the detector's `for await frame in source.frames` consumer is mid-inference on the previous frame when the seek-emit lands in the buffered stream, the buffering policy can drop it before consumption — no detection ever runs for that timestamp.

"Seek forward back toward where playback last was" recovers because continuous playback re-fills the 30-frame window. The user's "very good idea" intuition — *don't re-run the detector on already-seen timestamps* — is correctly the right structural answer and is not what the code does today.

## Design

A persistent, timestamp-keyed cache becomes the single source of truth for "what did the detector say about asset-time T?". Lookups are nearest-neighbor with an adaptive window; inserts are idempotent for a given timestamp bucket. The detector pipeline learns to consult the cache *before* running, skipping work when an entry already exists. Seek-emitted frames bypass the buffering race by being delivered through a path that guarantees consumption.

The `displayTime` divergence question gets answered as a side effect: once `lookup(at:)` is nearest-neighbor instead of exact-equality, the lookup-clock vs. detector-clock skew that the original `[open]` flagged stops mattering at the millisecond scale that actually trips up real playback.

## Public surface

`Sources/Iris/Overlay/ResultStore.swift` keeps its public type name and `@Observable` shape; storage and lookup semantics change:

- Storage: `[CMTimeQuantized: TimestampedDetections]` instead of `[TimestampedDetections]` array. Quantization bucket: one frame at the source's nominal frame rate (e.g. 1/30s for 30fps clips) — fine enough that distinct frames don't collide, coarse enough that floating-point seek targets land on the same bucket as the originally-detected frame. Quantization unit lives as a constructor parameter on `ResultStore` so callers can dial it.
- `lookup(at:)` returns the nearest-neighbor `TimestampedDetections` within an adaptive window (default: 2 × quantization unit forward or backward). The existing `stale:` parameter becomes a hard cap on the search window for safety; default stays at the M2 value.
- `contains(timestamp:)` (new) — cheap probe for the pipeline to use as a skip-gate. Bucket-aware.
- `clear()` survives unchanged. The current call sites (teardown only) keep working.
- Capacity bound deferred — no eviction in v1. M3 clips are seconds-long; revisit when M5's dataset workflows put long-form footage through the pipeline.

`Sources/Iris/Detection/DetectorPipeline.swift`:

- Gains an optional `cache: ResultStore?` parameter (or equivalent) on the per-frame entry point. When set, the pipeline calls `cache.contains(timestamp: frame.timestamp)` before dispatching detectors; on hit, skip; on miss, run detectors, write back. Backwards-compatible default: `nil` cache means today's "always run" behavior.

`Sources/Iris/Playback/PlaybackSource.swift`:

- Seek-emit guarantees delivery. Likely shape: replace the `.bufferingNewest(1)` policy with a small ring (`.bufferingNewest(3)`) for the playback source only — capture stays on `(1)` per the [`../DECISIONS.md`](../DECISIONS.md) hot-path contract. Alternative considered: separate `seekFrames: AsyncStream<Frame>` priority channel. Decided against on grounds of doubling the wire surface; revisit if `(3)` doesn't hold under detector congestion.

## Phases

### Phase 1 — `ResultStore` becomes timestamp-keyed nearest-neighbor cache

Rewrite storage from `[TimestampedDetections]` ring to `[CMTimeQuantized: TimestampedDetections]` dictionary keyed by quantized asset-time bucket. New `contains(timestamp:)`. `lookup(at:)` becomes nearest-neighbor with adaptive window. Constructor gains a `quantization: CMTime` parameter; default `CMTime(value: 1, timescale: 30)` matching the M2 fixture's 30fps. Migration: all existing call sites use the default; M3 demos pass through unchanged. Unit tests cover: quantization bucketing, nearest-neighbor across-the-bucket lookup, monotonic-time invariants, idempotent insert at the same bucket, `clear()` behavior, and the `stale:` hard-cap still applying. Drop the dead "call from `PlaybackSession.willSeek`" docstring.

### Phase 2 — `DetectorPipeline` cache-aware skip

Add cache parameter to the pipeline's per-frame entry. On `cache.contains(timestamp: frame.timestamp)` → skip dispatch (no allocation, no actor hop), pipeline returns the cached `TimestampedDetections` (or its no-op equivalent — the cache is the consumer, not the producer here). On miss → run as today, with the existing append-to-store path now also feeding the keyed cache. Demos rewire so the same `ResultStore` instance is passed to both the pipeline (write-through cache) and the `DetectionLayer` (read path). Test: a second invocation on a frame with the same timestamp doesn't call the detector. Use a `RecordingDetector` test double that increments a call counter.

### Phase 3 — Seek-frame guaranteed delivery

Switch `PlaybackSource` to `.bufferingNewest(3)` (or whatever the smallest backlog is that survives realistic detector inference time at 30fps). Add a stress test: drive the source through a slow `RecordingDetector` (artificial 100ms delay per frame), perform a `seek(to:)` mid-inference, assert the seek-emitted frame reaches the consumer. Document the policy choice and the rationale on `PlaybackSource`'s class doc, since it's a deliberate divergence from the [`../DECISIONS.md`](../DECISIONS.md) capture-side `(1)` contract.

### Phase 4 — Cross-platform smoke

Manual smoke on both iOS demo Playback tab and macOS demo. Cases: (a) backward-seek into already-played region → detections appear instantly (cache hit); (b) backward-seek into never-played region → detections appear within one detection cycle (~50-200ms, cache miss + run); (c) forward-seek into already-played region → cache hit; (d) random scrub-around stress → no visible gap; (e) frame-step backward repeatedly → cache hit chain after first run. Captures expected behavior in [`../LOG.md`](../LOG.md). Move the displayTime `[open]` in [`../QUESTIONS.md`](../QUESTIONS.md) to `[answered]` with a [`../DECISIONS.md`](../DECISIONS.md) entry pointing at this phase's commit.

## Open design questions surfaced

- **Quantization unit ↔ source frame rate.** Hard-coding `1/30s` on the constructor default leaks 30fps assumption. Options: (a) accept the fixed default and let callers override; (b) compute from the source's `nominalFrameRate` at `ResultStore.init` time (couples Source ↔ Store); (c) quantize to `CMTime`'s own internal resolution and trust AVF's bucketing. Lean toward (a) for now — explicit, simple, override exists. Revisit if M5 dataset workflows want a different default.
- **Cache-skip vs. detector non-determinism.** Vision rectangle detection is probabilistic; the same frame at the same timestamp can yield slightly different boxes on different runs. Cache-skip locks in *one* answer per timestamp. Fine for playback overlay; potentially wrong for M5 dataset capture (you'd want every detection run recorded, not deduped). Capture as an item for M5 to design around — possibly a separate "always-run" detector pipeline mode.
- **Cache memory growth on long videos.** No eviction in v1. A 60-minute clip at 30fps caches 108k entries × `TimestampedDetections` payload size. Probably fine in practice for M3/M4 demo scope; flag for M5 reconsideration.

## Risks

- **Test coverage shape.** Phase 3's stress test (mid-inference seek) is timing-sensitive and may flake. Mitigate by making `RecordingDetector`'s delay a deterministic `Task.sleep` and gating the assertion on a deterministic-ish lower bound; if it still flakes, mark as a `xfail`-style skip and rely on the manual smoke in Phase 4.
- **Cache-skip changes overlay refresh behavior.** Today every frame triggers an overlay re-render via `ResultStore`'s `@Observable` publish. With cache-skip, re-visiting a cached timestamp would *not* re-publish unless we explicitly bump the publication. Phase 2 needs to confirm the overlay re-renders on lookup (since `DetectionLayer` already reads `displayTimeSource` on a periodic timer) — if not, the read path needs a "notify-on-lookup" affordance.
- **Quantization-rate mismatch breaks lookups.** If a clip is 60fps but `ResultStore` is constructed with the 30fps default, two adjacent frames bucket together and one's detections overwrite the other's. Phase 1's constructor parameter is the workaround; demos need to pass the right value (or compute it from `AVAsset.tracks(withMediaType: .video).first?.nominalFrameRate`).
- **Capture-side `ResultStore` users are unaffected.** Capture uses host-clock timestamps; the same quantization scheme works (capture frames just happen to land in distinct buckets per tick), but the cache-skip optimization is meaningless there — every host-clock timestamp is unique. Capture demos shouldn't change behavior; confirm with the existing M2 iOS smoke.

## Exit criteria

- `ResultStore` is timestamp-keyed with nearest-neighbor lookup; no fixed-size ring buffer remains.
- `DetectorPipeline` consults the cache before dispatch; same-timestamp re-visits are zero-detector-calls.
- `PlaybackSource` delivers seek-emitted frames to the consumer reliably under detector congestion (stress-tested).
- Manual smoke on iOS Playback tab and macOS demo: backward seek into any-region shows correct detections, scrub-around shows no gaps beyond the first cache miss per timestamp.
- `[open]` displayTime divergence in [`../QUESTIONS.md`](../QUESTIONS.md) → `[answered]` with a [`../DECISIONS.md`](../DECISIONS.md) entry summarizing the nearest-neighbor lookup as the resolution.
- All public types compile under Swift 6 strict concurrency on both platforms. `swift test` green; `xcodebuild` for both demo targets green.
