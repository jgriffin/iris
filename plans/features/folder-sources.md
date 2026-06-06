# Folder sources — pick a folder, browse it in the sidebar

<!-- M13 working plan: definition, settled forks, phases, opens. Status vocab
     per WORKFLOW.md. -->
_Captured · 2026-06-05 · picked up as **M13** 2026-06-05_ · **📋 defined — phases drafted, P1 next** · branch `m13-folder-sources`

## What & why (user, 2026-06-05)

The Playback and Image sections can open single files; the common real-world
shape is **a folder where a bunch of things exist** (a shoot, a clip dump, an
export directory). The user wants to pick an **entire folder**, see it in the
sidebar as a **collapsible block** listing its matching contents, and pick
items from it to load — without losing the existing RECENT behavior.

## Settled at capture (user)

- **Both sections.** Playback (videos) + Image (stills). Capture has no file
  source; Dataset/model picking unaffected.
- **MRU of folders**, not one active folder — same recency discipline as
  `RecentVideos`/`RecentImages`, applied to folders.
- **Items picked from a folder land in RECENT as usual** — folder browsing
  *feeds* the existing recents, it doesn't replace them.
- **Sequencing:** after M12·P4 — penciled as the next milestone candidate.

## Settled at pickup (2026-06-05)

- **Importer shape: two new `ImportTarget` cases** — `videoFolder` +
  `imageFolder` (`contentTypes = [.folder]`), not a folder axis on the
  existing cases: `handlePicked` already routes by case, and the two folder
  kinds filter children differently anyway. Rides the post-`749e798`
  presentation/payload split unchanged.
- **Stock pickers on both platforms** — macOS `.fileImporter` and the iOS
  `DocumentPicker` wrapper both accept `UTType.folder` and return the
  directory URL with security scope; one folder bookmark covers its children
  (the existing `user-selected.read-only` entitlement suffices). No custom
  `NSOpenPanel`.
- **Enumeration: shallow + filtered** — non-recursive `contentsOfDirectory`,
  children filtered by UTType conformance (movies for Playback, images for
  Image), name-sorted. Freshness = re-enumerate on expand (P4 confirms it
  suffices).
- **P1 = the shared-MRU-generic pull-in, behavior-preserving** — factor the
  bookmark-backed core out of `RecentVideos`/`RecentImages` (same defaults
  keys, no migration; the two types stay thin wrappers, call sites untouched),
  then `RecentFolders` (`iris.recent.folders.v1`) is the third instance.
  Reverses M8·P4's "deliberate siblings" — the third sibling is the forcing
  function. → [BOARD §Backlog](../BOARD.md)
- **Design-pass-first inside P3** — block placement + multi-folder
  presentation settle in a `#Preview` gallery (M9·P6 style) *before* the live
  wiring.

## Phases

- 📋 **P1 — Shared MRU generic + `RecentFolders`.** Factor the bookmark-backed
  MRU core (UserDefaults `[Data]` bookmark persistence, platform-gated
  bookmark/resolve flags, `addOrPromote` dedup-by-path, stale-refresh
  `resolve()`, `clear()`) into one base in `Apps/Shared/State/`;
  `RecentVideos`/`RecentImages` become thin wrappers (defaults keys + call
  sites untouched); add `RecentFolders`. Exit: both schemes green, recents
  behave identically, `Iris` library untouched.
- 📋 **P2 — Folder pick + filtered child listing.** `ImportTarget` gains
  `videoFolder`/`imageFolder`; both pickers accept `UTType.folder`;
  `handlePicked` routes folder picks to `recentFolders.addOrPromote` + scope
  bookmarking; a small shallow-enumeration helper filters children by content
  type per mode. Exit: a picked folder lands in the folders MRU and yields the
  right children (log-observable; the sidebar surface is P3).
- 📋 **P3 — Sidebar FOLDER block — in-canvas design pass, then live wiring.**
  `#Preview` gallery with fixture listings; the user settles placement (above
  vs below RECENT) + multi-folder presentation (all collapsible vs
  one-expanded-at-a-time) live in the canvas; then wire it — expand →
  (re-)enumerate, child tap → `swapToExternal`/`pickImage` (RECENT promotion
  for free), folder promoted in its MRU on use. Exit: design user-confirmed in
  canvas, working on both platforms.
- 📋 **P4 — Polish + remaining opens.** Large-folder cap + "N more…" (lean
  v1); confirm re-enumerate-on-expand freshness; ⚖️ MRU-entry removal (user
  call: in or stays backlog); static preview gallery cases light + dark; full
  test pass + both schemes green; smoke + merge prep.

## Opens (settle in-phase)

- ⚖️ **Placement + multi-folder presentation** (→ P3, in-canvas) — above vs
  below RECENT; all collapsible vs one expanded at a time. Settle the M9·P6
  way — live in a `#Preview` gallery, not on paper.
- ⚖️ **MRU entry removal** (→ P4) — user: "probably need a right-click to
  remove things from the MRU as well. Well, maybe." If it lands, it applies to
  file recents too (macOS context menu; iOS long-press) — small to add over
  the P1 generic.
- ⚖️ **Large-folder behavior** (→ P4) — cap the listed children? lazy
  enumeration? (A shoot folder can hold hundreds of clips.) Lean: a simple cap
  + "N more…" is probably enough for v1.
- ⚖️ **Folder-content freshness** (→ P4) — re-enumerate on expand vs watch the
  directory. Lean: re-enumerate-on-expand is almost certainly enough.
