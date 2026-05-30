# Unified sidebar nav — one cross-platform shell

<!-- Working plan. Lifetime ~ this milestone; LOG.md keeps the trail. Status vocab per WORKFLOW.md §"Status trees". -->
_Penciled — sequenced after M8·P5 (freeze-from-live) + M8·P6 (dataset tie-in). No number until taken on._

## Intent

Replace the two divergent demo shells with **one** custom cross-platform sidebar.
Today iOS uses a `TabView` with `.sidebarAdaptable`; macOS uses a `Videos | Images`
segmented picker. Both were stood up in M8·P4 as **interim nav seeds** — the iOS
tab and the macOS mode-toggle — and were known at the time to be temporary. The
macOS stacked-`.fileImporter` latent bug is likewise an interim seed: a symptom of
the un-unified shell. This pass **subsumes all three** — one shell, built once,
shared across iOS, iPadOS, and macOS, with the divergence collapsed rather than
papered over.

## Reference mockups

The user provided iPhone + iPad reference mockups on 2026-05-29:

![Unified sidebar mock — iPhone (collapsed sidebar + bottom-sheet inspector) and iPad (persistent split sidebar)](assets/unified-sidebar-mock.png)

On **iPad / macOS**, the layout is a persistent split: a fixed sidebar on the left
(Iris title, a `MODEL` section pinned to the top, page-rows in the middle, a
`DATASET` strip pinned to the bottom) and the detail on the right (the video/image
frame with overlay boxes, transport controls, and a docked inspector). On **iPhone**,
the same content reflows for a compact width: the sidebar collapses behind a
top-left toggle (a drawer), and the inspector — `LIVE DETECTIONS` + `METRICS` —
becomes a bottom sheet with a drag handle. The bookmark affordance sits top-right of
the detail on every size class.

```
iPad / macOS (persistent split sidebar)        iPhone (sidebar → drawer, inspector → bottom sheet)
┌─ Iris ──────────────[⊟]┐ ┌─────[🔖]┐         ┌[⊟]──────────────────[🔖]┐
│ ⌄ MODEL                 │ │         │         │   ┌──────────────────┐   │
│ ┌─────────────────────┐ │ │  video  │         │   │  video frame +   │   │
│ │ 🎥 YOLO26n (Core ML)⇅│ │ │  frame  │         │   │  overlay boxes   │   │
│ │ Min confidence  0.25 │ │ │ +boxes  │         │   └──────────────────┘   │
│ │ ───●──────────────── │ │ │         │         │   ◀  ❙❙  ▶  (transport)  │
│ └─────────────────────┘ │ │         │         ├───────── drag ───────────┤
│ ▶ Playback           •  │ │ scrubber│         │ Inspector   33·0drop·7ms  │
│ ┌─────────────────────┐ │ │ ◀ ▶ ▶│ │         │ LIVE DETECTIONS  t=1.08·2 │
│ │ ⊞ Open Video…       │ │ │         │         │   Raw values        ( ○) │
│ └─────────────────────┘ │ │         │         │   ● person  …yolo26n 88% ›│
│ RECENT                  │ │inspector│         │   ● sports ball     43% ›│
│   🎥 basketball_test_1  │ │ (docked,│         │ METRICS                   │
│   🎥 clipboard-blank    │ │  faded) │         │   Frames  33 emit·33 proc │
│   🎥 dancer-full-body   │ │         │         │   Dropped         0 (0%)  │
│ 📷 Capture              │ │         │         │   Inference avg7ms·last8ms│
│ ─────────────────────── │ │         │         └───────────────────────────┘
│ DATASET  2 exported [⬆ Export]                
└─────────────────────────┘ └─────────┘         
```

## Structure

- **Global MODEL section, pinned top.** Detector picker + a Min-confidence slider.
  This is **app-level shared state** — one active model + one confidence knob for the
  whole app, not per-page.
- **Page-rows: Playback / Image / Capture.** The *active* page expands inline to
  reveal its **Open …** primary button + its **RECENT** list; inactive pages collapse
  to bare rows. Selecting a row navigates and expands it.
- **DATASET, pinned bottom.** Export status + an **Export** button — the natural home
  for M8·P6's dataset tie-in.
- **Toolbar bookmark, top-right of the detail.** The M7 flag affordance, promoted to
  the toolbar — the natural home for M8·P5's freeze / inspect handoff.
- **iPad / macOS.** A persistent `NavigationSplitView` sidebar; the inspector docks
  inside the detail.
- **iPhone.** The sidebar collapses to a drawer (top-left toggle); the inspector
  becomes a bottom sheet (`.presentationDetents` + a drag handle) carrying
  `LIVE DETECTIONS` + `METRICS`.

## Architectural change (the heart of it)

The substance of this milestone is collapsing the **four independent per-page
`selectedDetectorID`s** + their per-page tuning into **one app-level shared model
selection + confidence**. Today those four selections live at:

- iOS Playback — `Apps/IrisDemo-iOS/ContentView.swift:303`
- iOS Image — `Apps/IrisDemo-iOS/ImageContentView.swift:51`
- macOS Videos — `Apps/IrisDemo-macOS/ContentView.swift:146`
- macOS Images — `Apps/IrisDemo-macOS/ContentView.swift:187`

The global model drives **all three pages, Capture included**. Capture is today
**hardcoded to Vision rectangles with no picker** (`Apps/IrisDemo-iOS/ContentView.swift:136`),
so wiring the shared model through it makes **live-capture detector-swap net-new
work pulled into this milestone**, not a free side effect. `recentDetectors` +
`modelStore` are **already shared per-platform** (`Apps/Shared/`), so they fit the
unified store cleanly — only the per-page selection state needs to consolidate.

## Subsumes / fixes

- **The M8·P4 nav seeds** — the iOS tab and the macOS `Videos | Images` toggle. Both
  were always interim; this pass replaces them with the unified sidebar.
- **The macOS stacked-`.fileImporter` latent bug.** The root view stacks a movie
  importer and a model importer; SwiftUI honors only **one** `isPresented` importer
  per view, so the second silently never presents (`Apps/IrisDemo-macOS/ContentView.swift:415`
  + `:434`). The unified shell gives each page (and each importer) its own node — fix
  it as part of the reshuffle. General rule: **one presentation modifier per view.**
- **Relates to** (does not fully close) the "shared MRU generic" backlog item — the
  `RecentImages` / `RecentVideos` factoring. The sidebar touches that surface but
  doesn't oblige the refactor.

## Open forks (resolve at pickup)

- **Where the app-level shared model state lives** — likely an `@Observable` store in
  `Apps/Shared/`, but the exact shape is open.
- **The Capture detector-swap mechanism** — Capture's live stream needs an in-place
  router swap analogous to playback; pin the exact wiring at pickup.
- **Whether per-page tuning ever diverges from the global confidence.** Today it's a
  single global knob; the richer per-category axis is tracked separately (see the
  "per-category tuning" backlog item) and is not assumed here.

## Sequencing note

Built **after** M8·P5 (freeze-from-live) and M8·P6 (dataset tie-in). Accepted cost:
P5/P6 wire into the **interim P4 nav**, which this pass then rewrites. The trade is
deliberate — both P5 and P6 reuse the coordinator / MRU plumbing that **survives the
reshuffle**, so the throwaway is confined to the nav shell, not the feature work
underneath it.
