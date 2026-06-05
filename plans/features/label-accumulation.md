# M12 — Label accumulation

_Penciled in 2026-06-04; number assigned at pickup 2026-06-04 (the milestone
right after M11 merged). Grows the M10·P3 backlog one-liner ("present-label
accumulation") into a full milestone. **Pivoted 2026-06-04** — the per-source
ledger was dropped for one per-detector store; see [§Settled history](#settled-history)._

## Goal

Steady the per-class roster in the unified tuning panel, and **widen** it. Today
the roster derives from the **current frame's** detections, so rows flicker as
labels come and go. We want the panel to answer "**what has this detector
detected**" — a stable working list that doesn't jitter frame-to-frame and that's
already there when you reopen.

> Run a basketball clip and watch `person` / `sports ball` / `clock` settle into
> a stable list instead of strobing; switch detectors and the list switches with
> it; the labels you pinned/hid/floored last session are right where you left them.

The mechanism is **one per-detector store that IS the whole panel's per-class
state** — accumulated sightings *and* the user's show/hide/floor opinions in a
single map, keyed by detector. No source layer, no scope stepper.

## Design

### Schema (user-seen + approved, 2026-06-04)

```jsonc
{
  "version": 1,
  "detectors": {
    "coreml.yolo26n": {
      "person":       {},                           // seen; no opinion → Auto
      "sports ball":  { "visibility": "show" },     // pinned — always draws
      "chair":        { "visibility": "hide" },     // never draws
      "dog":          { "floor": 0.45 }             // per-label floor, visibility Auto
    },
    "coreml.yolov12": {
      "person":       { "visibility": "show" }
    }
  }
}
```

```swift
struct LabelState: Codable {
    var visibility: Visibility?   // nil = Auto
    var floor: Float?             // nil = global floor fallback
}
// detector catalog ID → label → LabelState; {} is meaningful: "seen"
```

The detector keys are real `DetectorCatalogEntry.id`s (`coreml.yolo26n`,
`coreml.yolo12n`, `vision.rectangles`, …) — the same id the picker binds to via
`ModelSelection.detectorID`.

### Semantics

- **Key membership = accumulation; values = the user's opinions.** A label enters
  a detector's map the first time that detector emits it. `{}` (an empty
  `LabelState`) means "seen, you never said anything" — the tri-state **Auto**
  default.
- **One store, not two.** Sightings and show/hide/floor settings live in the same
  map — there's no separate ledger + settings pair that must be kept in agreement.
  The per-label floor and tri-state visibility that are **global today** become
  **per-detector** (they ride in this store, keyed under the detector).
- **Accepted semantic blur.** Pinning "show" (or hiding, or setting a floor) on a
  not-yet-seen label — reached via the full-roster expander — creates its entry.
  So membership is really "seen **OR** opined-on." That's fine: an opined-on label
  belongs in the working list regardless.
- **No source identity anywhere.** `AssetFingerprint` exits M12. No per-video
  union, no scope stepper. The panel keeps M11's **binary expander**: the
  accumulated **seen labels** (stable, no flicker) ▸ the detector's **full
  roster** (`availableLabels`). The old L0–L3 ladder collapses to effectively
  frame → detector-wide → roster, with **detector-wide as the default**.
- **All three modes feed it.** Playback, Image, **and** Capture write sightings.
  The video-first restriction existed only because of per-video identity, which is
  gone. Each write is an idempotent key-insert; dedupe is just a membership check.
- **Clear = forget sightings only.** The per-detector clear removes entries whose
  `LabelState` is empty/default (no explicit visibility, no floor) — **explicit
  opinions survive** a roster reset. You get a fresh "what's been seen" list
  without losing your pins/hides/floors.
- **Detector-keyed by construction.** A YOLO `person` and another model's `person`
  never share history or opinions — switching the detector switches the whole
  per-class view. (User: "different detectors have different categories.")
- **Persisted.** UserDefaults/JSON, with the `version` field retained for future
  migration. Label strings + a tiny struct are cheap.
- **App-side only.** Lives in `Apps/Shared/State/`. The `Iris` library does not
  change — the overlay still consumes the library `OverlayFilter`, which the store
  assembles for the active detector exactly as `ModelSelection` does today.

### Naming

It's no longer a "ledger" (no append-only sighting log; it's the panel's whole
per-class state). Working name **`DetectorLabelStore`** — a per-detector map of
label → state. The `LabelState` value type and the `Visibility` enum live with
it. *P1 confirms the final type names.*

## Migration note — which Apps/Shared state the store absorbs

Today the per-class state is **global** (one flat namespace, not keyed by
detector) and lives entirely on `ModelSelection`
(`Apps/Shared/State/ModelSelection.swift`). The new per-detector store **absorbs
three of its fields, re-keyed under the detector id**:

| `ModelSelection` today (global) | Becomes (per-detector, in the store) |
| --- | --- |
| `perLabelMinConfidence: [String: Double]` | `LabelState.floor` per `(detector, label)` |
| `hiddenLabels: Set<String>` | `LabelState.visibility == .hide` |
| `pinnedLabels: Set<String>` ("Show") | `LabelState.visibility == .show` |

Along with the behavior that hangs off those fields, today all on
`ModelSelection`:

- `LabelVisibility` enum (`hide` / `auto` / `show`) → the store's `Visibility`
  (`auto` = the `nil`/absent case, not a stored value).
- `visibility(of:)`, `setVisibility(_:for:)`, `cycleVisibility(of:)`,
  `setPerLabelFloor(_:for:)` → move onto the store, taking the active detector id.
- `overlayFilter: OverlayFilter` (the computed library filter, with its
  clamp-to-global belt-and-suspenders) → assembled from the active detector's
  slice of the store.

**Stays on `ModelSelection`, unchanged:**

- `detectorID` — the selection the store is keyed *by* (the store reads it to pick
  its active slice). The picker still binds here.
- `minConfidence` (the global "Min confidence" floor) — this is the **global**
  render floor, the fallback every per-label `floor` clamps to. It is *not*
  per-class state, so it stays global on `ModelSelection`. (Whether it ever goes
  per-detector is out of scope — see below.)

**Read-only, not absorbed:** `presentLabels` in `IrisShell.swift` is *derived*
from `ResultStore.lookup(at:)` each render (no persistence) — it's the live
"current frame" set. P2 turns those same sightings into store writes; P3's roster
reads from the store instead of (only) from `presentLabels`, which is why the
flicker goes away. `presentLabels` stays as the "currently drawn" signal that
marks rows live vs. accumulated.

**What complicates the "store absorbs the panel state" story (call-outs):**

- **The clamp-to-global coupling.** `overlayFilter` and `setPerLabelFloor` clamp
  every per-label floor to `≥ minConfidence`, and `PerClassRow`'s slider uses the
  global floor as its lower bound + fallback. The store now owns the floors but
  the global floor still lives on `ModelSelection`, so the store's filter assembly
  (and the row UI) must read `ModelSelection.minConfidence` to clamp. Two objects
  participate in one computed filter — keep that seam explicit in P1/P3.
- **Tri-state ⇆ schema shape mismatch.** Today visibility is **two sets**
  (`hiddenLabels`, `pinnedLabels`) kept mutually exclusive; Auto = "in neither."
  The store collapses that to one optional enum (`visibility: Visibility?`, `nil`
  = Auto). The migration is lossless but the *meaning of absence* changes: today
  "absent from both sets" = Auto; in the store a key can be **absent entirely**
  (never seen) **or** present with `visibility == nil` (seen, Auto). The panel's
  working set must treat "no entry" and "entry, Auto" the same for drawing but
  differently for listing (only seen/opined-on labels list).
- **Migrating existing stored defaults — SETTLED 2026-06-04: start clean (no
  migration).** `ModelSelection` persists the three global maps under `.v1` keys
  today, with no detector attribution. The new `DetectorLabelStore` simply **does
  not read** them — it starts empty and the old `.v1` per-class keys
  (`perLabelMinConfidence`, `hiddenLabels`, `pinnedLabels`) are no longer
  consulted by anything. There's no real corpus yet, so folding the unattributed
  global maps into a best-guess detector slice would invent attribution that isn't
  there; start-clean is simpler and honest. (`ModelSelection`'s remaining keys —
  `detectorID`, `minConfidence` — are untouched and still load as before.)
- **`PerClassControls` / `PerClassRow` bind `@Bindable var modelSelection`
  directly** and read its fields (`hiddenLabels`, `pinnedLabels`,
  `perLabelMinConfidence`, the tri-state helpers). Rewiring the panel (P3) means
  re-pointing those bindings at the store (passing the active detector id), not
  just swapping a data source — the row's reset/override/eye affordances all call
  `ModelSelection` methods that move.

## Phases

- **P1 — The store.** New app-side `DetectorLabelStore` (`Apps/Shared/State/`):
  the `detector id → label → LabelState` map + the `LabelState`/`Visibility`
  types; UserDefaults/JSON persistence with the `version` field; the per-detector
  **clear-sightings-only** op (drop empty/default entries, keep opinions); the
  visibility/floor accessors (`visibility(of:in:)`, `setVisibility`,
  `cycleVisibility`, `setPerLabelFloor`) and the `overlayFilter(for:globalFloor:)`
  assembly absorbed from `ModelSelection`, clamped to the global floor.
  **Legacy-migration call SETTLED (2026-06-04): start clean** — the store does not
  read the old `ModelSelection` `.v1` per-class keys; it starts empty.
  Unit-test where reachable — note the standing `Apps/Shared/`
  test-reachability caveat (as with `RecentVideos`). *This is the
  integration-heavy phase: it lifts live per-class state off `ModelSelection`.*
- **P2 — Feed it (all three modes).** Insert sighting keys from the detection
  paths of **Playback, Image, and Capture** — the same `Detection.label`s
  `presentLabels` already derives, recorded into the active detector's slice.
  **Idempotent + write-on-change only**: skip writes that add nothing (membership
  check), so the hot loop only touches the store when a genuinely new label
  appears. Empty-string labels (class-agnostic detectors) are filtered out, as
  today.
- **P3 — Panel rewiring.** The roster derives from the **store's keys** for the
  active detector (stable, no flicker) instead of from `presentLabels` alone;
  `presentLabels` stays the "currently drawn / live" marker. The **M11 binary
  expander is retained** (seen labels ▸ full roster via `availableLabels`); add
  the per-detector **clear** affordance. Tri-state eye + per-label floor rows
  read/write the store (for the active detector) rather than `ModelSelection`.
  Re-point `PerClassControls`/`PerClassRow` bindings at the store + the active
  detector id.
- **P4 — Polish + static preview.** Empty states (fresh detector with no
  sightings; class-agnostic detector with no roster); detector-switch behavior
  (the view follows the active detector's slice); a **static preview gallery**
  (the favorite pattern) covering accumulated-only / mixed-opinion / cleared /
  no-roster panels, light + dark; both demo schemes green, full test pass.

_(Four phases, ≤5. Migration isn't its own phase — it's inseparable from standing
up the store, so it lives in P1; the panel-binding rewire is the P3 integration.)_

## Out of scope / fast-follows

- **Per-source / per-video scoping.** Could return later as a *layer over* this
  store (`sourceKey → seen-labels`) if the corpus-vs-single-video distinction ever
  earns its UI. `AssetFingerprint` was the planned key. Parked as a backlog stub
  → [`BOARD.md`](../BOARD.md) §Backlog.
- **Per-detector global floor.** `minConfidence` stays a single global control;
  making the global floor itself per-detector is a separate question, not M12.
- **Config profiles** — named settings bundles across detectors; its own backlog
  item. → [`BOARD.md`](../BOARD.md) §Backlog (Per-class config profiles).
- **Any recency/count display** — membership is presence-only; "last seen" / "how
  often" are not in scope.

## Settled history

### 2026-06-04 (afternoon) — Pivot: one per-detector store, no sources (user)

The user reviewed a concrete example of the morning's per-source ledger and
rejected the source layer outright — "the sources bit gets in the way… makes
everything unreadable." **This supersedes specific points of the morning's
Settled round** (below), but not the milestone's existence or goal:

- ❌ **Sources dropped.** No `sourceKey`, no `AssetFingerprint` in M12, no
  per-video union. Per-video scoping → backlog stub.
- ❌ **Scope stepper dropped.** The M11 **binary** expander (seen ▸ roster) is
  retained; the planned This-video ▸ All-videos ▸ Full-roster step is gone.
- ✅ **Video-first lifted.** All three modes (Playback, Image, Capture) feed the
  store — the restriction only existed because of per-video identity.
- 🔁 **"Roster-only / settings stay global" reversed.** The store now **absorbs**
  the per-class settings: per-label floors and tri-state visibility become
  **per-detector** and live in the store, not global on `ModelSelection`. One
  store = sightings **and** opinions, no separate ledger/settings pair.
- ✅ **Clear = forget sightings only** — empty/default entries drop; explicit
  opinions survive.
- The milestone keeps its name/number (**M12 — Label accumulation**). Schema +
  semantics above are the user-approved shape. Type name (`DetectorLabelStore` or
  similar) is P1's to confirm.

### 2026-06-04 (morning) — Original definition + first Settled round *(superseded in part)*

The milestone was first defined as a **scope ladder** — **L0 Frame → L1 Video →
L2 Detector → L3 Roster** — powered by one per-detector **label ledger**, the
minimal sighting set `(detectorID, sourceKey, label)`, with the M7
`AssetFingerprint` as the video `sourceKey`. First Settled round: **video-first**
(Playback only; Image/Capture fast-follows), default scope **L2 (All videos)**
with **ephemeral** narrowing, **presence-only** (no `lastSeen`), **roster-only**
(per-class settings stay global), a per-detector **clear seen labels** button.

**What the pivot kept:** the per-detector keying, persistence, the
detector-wide-by-default roster, the clear affordance, presence-only membership,
app-side-only / no library change. **What it dropped/reversed:** the source layer
(`sourceKey`/`AssetFingerprint`), the L0–L3 ladder + scope stepper, the
video-first restriction (now all three modes), and "settings stay global" (the
store now owns them per-detector). The original ladder rationale is preserved here
for history; the [§Design](#design) above is the live spec.

## Related

- [`features/per-class-tuning.md`](./per-class-tuning.md) — M10/M11 predecessor;
  the per-class panel this store feeds, where the present-only default + the M11
  "show all" expander + the tri-state/floor rows live.
- [`features/M7.md`](./M7.md) — `AssetFingerprint` (was the planned video
  `sourceKey`; out of M12, parked for the per-video-scoping backlog stub).
