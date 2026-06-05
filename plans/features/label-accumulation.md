# M12 — Label accumulation — multi-level roster scope

_Penciled in 2026-06-04; number assigned at pickup 2026-06-04 (the milestone
right after M11 merged). Grows the M10·P3 backlog one-liner ("present-label
accumulation") into a full milestone._

## Goal

Steady the per-class roster in the unified tuning panel, and **widen** it. Today
the roster derives from the **current frame's** detections, so rows flicker as
labels come and go. We want the panel to answer "**what's getting detected**" —
in *this* video, and across a *corpus* of similar videos run through the same
detector — without the list jittering frame-to-frame.

> Run a basketball clip and watch `person` / `sports ball` / `clock` settle into
> a stable list instead of strobing; open the next clip from the same camera and
> see the same working roster already there; flip to "All videos" to see every
> class this detector has ever surfaced across the whole corpus.

## Design intent (settled in conversation — see [`DECISIONS.md`](../DECISIONS.md) 2026-06-04)

- **Roster-only.** Accumulation remembers **which labels have been seen** — a
  pure sighting history. The user: "I care about which labels show up — what's
  getting detected — not the settings." **Per-class settings stay where they are
  today**: per-class floors + visibility remain **global** (one map in
  `ModelSelection`); per-scope settings stay deferred to the **config-profiles**
  backlog item. Clean seam: profiles = settings bundles, ledger = sighting
  history — different concerns, different stores.
- **One mechanism — a label ledger.** A small, app-side, append-only record of
  `(detectorID, sourceKey, label, lastSeen)`. **Every accumulation level is a
  union query over it.** No per-level machinery.
- **Keyed by detector by construction.** A YOLO `person` and another model's
  `person` never share row history — switching detectors switches the whole
  accumulated view. (User: "different detectors have different categories, so I'm
  not sure we can get away from doing it per detector.")
- **Persisted.** UserDefaults/JSON, per-detector — label strings are tiny. Bonus:
  reopening a video pre-seeds its rows *before* play.
- **App-side only.** All of this lives in `Apps/Shared/`; the **`Iris` library
  should not need to change** (the roster is already fed from `ResultStore`
  detections + `DetectorCapabilities.availableLabels`, both shipped).

## The scope ladder

Each level **strictly contains** the one below it:

| Level | Name | Source of labels |
| --- | --- | --- |
| **L0** | Frame | labels in the **current frame** (today's default — flickers) |
| **L1** | Video | union of labels seen **since this video opened** (the original backlog item) |
| **L2** | Detector | union across **ALL** videos / images / captures ever run with this detector |
| **L3** | Roster | `availableLabels` — the **full class list** (already shipped in M11 as "show all classes") |

**L0 and L3 already exist** (L0 = today's present-only default; L3 = M11's "show
all"). **L1 and L2 are the new ground** — and the ledger is exactly what powers
them. L0 comes straight from detections, L3 from capabilities — neither needs the
ledger.

## Mechanism — the label ledger

A single append-only store; every level is a filter over it:

- **L1 (Video)** = filter to `(current detector, current source)`.
- **L2 (Detector)** = filter to `(current detector)`, all sources.
- **L0 / L3** bypass the ledger (detections / capabilities respectively).

**`sourceKey` — the source identity:**

- **Videos** → the M7 `AssetFingerprint` (`byteSize` + `durationSeconds` +
  head-hash; filename display-only). Content-keyed and **rename-stable** — exactly
  the right identity. → [`features/M7.md`](./M7.md)
- **Stills** → an image fingerprint (image-shaped `AssetFingerprint`, the M8
  backlog item — `durationSeconds` dropped). → [`features/M8.md`](./M8.md)
- **Live capture** → an ephemeral session marker (no durable identity). Capture
  has no stable source, so **capture feeds L2 only** — it can't anchor an L1
  video scope.

## UI shape

- **Default roster = L1.** This alone kills the flicker — the list is the union
  since the video opened, not the current frame.
- **Pinned "Show" rows** stay present regardless of scope (already true in M11).
- **The M11 "show all classes" expander generalizes** from a binary toggle into a
  **scope step**: **This video ▸ All videos ▸ Full roster** (L1 → L2 → L3).
- **Accumulated-but-not-currently-detected** rows render like absent roster rows
  do in M11's expanded view (dimmed / present-as-history).
- **Reset semantics:**
  - *Detector change* → switches the whole query (the ledger is keyed on detector).
  - *Source change* → L1 moves to the new source's union.
  - *L2* only ever **grows** → consider a **"clear history"** affordance for hygiene.

## Non-goals

- **No automatic video-similarity grouping.** Two reasons: (1) **L2 is the cheap
  90%** — same-kind videos through the same model converge on the same working
  label subset for free. (2) Explicit grouping already has a home: the
  **config-profiles** backlog item — a profile is a *named* scope carrying roster
  + settings; the ledger leaves a slot for it (a profile = another grouping over
  `sourceKey`s). → [`BOARD.md`](../BOARD.md) §Backlog (Per-class config profiles)
- **No per-scope settings.** Floors/visibility stay global; per-scope bundles are
  the config-profiles item, not this one.

## Sizing

Meaningfully bigger than the original one-line backlog item (which was in-memory
**L1 only**): this adds **persistence**, **source identity for images**, the
**scope-step UI**, and **reset/clear semantics**. Still all app-side
(`Apps/Shared/`) — the library doesn't move.

## Opens

- ❓ **Image-fingerprint shape.** Exact form of the still `sourceKey` — the
  image-shaped `AssetFingerprint` is the adjacent M8 backlog item; settle it
  there or here at pickup. → [`features/M8.md`](./M8.md)
- ⚖️ **Where the ledger store lives** in `Apps/Shared/State/` — a sibling to
  `ModelSelection` (keep `ModelSelection` from bloating), persistence shape
  (UserDefaults JSON blob vs. a tiny file).
- ⚖️ **Scope stepper lifetime** — is the chosen scope (L1/L2/L3) per-panel-session
  (resets each open) or persisted with the detector?
- ⚖️ **Ledger size hygiene** — cap entries (per detector? per source?) and/or a
  user-facing **"clear history"**. L2 only grows; decide the cap before it matters.

## Related

- [`features/per-class-tuning.md`](./per-class-tuning.md) — M10/M11 predecessor;
  the per-class panel this roster feeds, and where the present-only default + the
  M11 "show all" expander live.
- [`features/M7.md`](./M7.md) — `AssetFingerprint` (the video `sourceKey`).
- [`features/M8.md`](./M8.md) — image-shaped `AssetFingerprint` (the still
  `sourceKey`, backlog).
