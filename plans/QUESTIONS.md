# Open questions

<!-- OPEN questions only — ⚖️ needs-decision / ❓ genuine-unknown. This file is the dossier home:
     each item = a scannable headline + its detail paragraph.
     · Settled → move to DECISIONS.md (prepend a `Q:` line there); delete the copy here.
     · Deferred WORK (a chore/bug/idea with nothing to decide) → BOARD.md §Backlog; delete the copy here.
     File references should be clickable markdown links. -->

- ⚖️ **Source-agnostic decomposition of `PlaybackDetectionCoordinator`.** The coordinator ([`features/playback-detection-coordinator.md`](./features/playback-detection-coordinator.md)) lives in `Sources/Iris/Playback/` because it's playback-coupled — it owns a `PlaybackController` and needs `seek` for the `onDetectorTierChange` pause-emit hook (placement decided, [`DECISIONS.md`](./DECISIONS.md) 2026-05-27). But its detect-loop + `ResultStore` + `DetectionMetrics` core is genuinely **source-agnostic**, and a future **capture-side** detection consumer would want it. Open: when capture-side detection lands, lift that core into a `Detection/`-side `DetectionRunner` the coordinator composes (the coordinator's deferred P4). Per the repo's "splitting later is non-breaking" single-target doctrine, **do not pre-split** — build the concrete coordinator now, decompose only when the second consumer materializes. See the [`RECOMMENDATIONS.md`](../explorations/2026-05-27-demo-library-boundary/RECOMMENDATIONS.md) caveat.

- ⚖️ **Multi-detector pipelines under `TuningModel`.** When a `DetectorPipeline` runs more than one detector, does each detector get its own `TuningModel<Settings>`, or is there a composite settings model spanning them? M4 shipped with the one-detector-one-model shape; the composite design is deferred. Resolve when a real multi-detector pipeline lands (post-M4). Multi-active detector selection also defers here. See [`features/M4.md`](./features/M4.md) §"Open design questions".

- ⚖️ **"What if?" mode from `BRIEF.md` §5.** Show detections that *would* pass at a lower threshold rendered in a distinct style — a view-tier overlay over a detector-tier change (you need the lower-threshold detections cached to display them). Cleanest sketch: a dedicated `previewSettings` channel running alongside live settings, materializing the cache for the preview values; the overlay renders both layers. Deferred to a follow-up feature; M4 closed without it. See [`features/M4.md`](./features/M4.md) §"Open design questions" and [`BRIEF.md`](./BRIEF.md) §5.
