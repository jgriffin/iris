# Folder sources — pick a folder, browse it in the sidebar

<!-- Penciled feature: definition + settled forks + opens. Phases drafted at
     pickup (milestone number assigned then, per the naming convention).
     Status vocab per WORKFLOW.md. -->
_Captured · 2026-06-05_ · **📋 penciled — pick up after M12 closes**

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

## Design sketch (assistant, at capture)

- **Pick.** Folder selection rides the existing enum-routed importer
  (`ImportTarget` + `importerPresented`, post-`749e798` shape): macOS
  `.fileImporter` accepts `UTType.folder`; iOS `DocumentPicker` likewise.
  Either new enum cases (`videoFolder`/`imageFolder`) or a folder axis on the
  existing cases — decide at pickup.
- **Scope.** A folder is one security-scoped bookmark; scope on the folder
  covers its children on both platforms (the existing
  `user-selected.read-only` entitlement suffices). Enumerate + filter children
  by content type (movies for Playback, images for Image); shallow,
  non-recursive first cut.
- **Sidebar.** A collapsible FOLDER block per mode section listing matching
  children; tapping a child routes through the same load path as a pick
  (`swapToExternal` / `pickImage`), which also promotes it into RECENT.
- **Persistence.** A `RecentFolders` MRU (bookmark-backed UserDefaults, MRU
  order, stale-drop) — the third near-identical sibling alongside
  `RecentVideos`/`RecentImages`. **This is the moment the backlog's "shared
  MRU generic" item gets pulled in** rather than writing the pattern a third
  time. → [BOARD §Backlog](../BOARD.md)

## Open at capture

- ⚖️ **Placement** of the folder block within the mode section (above vs
  below RECENT) + how multiple MRU folders present (all collapsible? one
  expanded at a time?). Settle the M9·P6 way — live in a `#Preview` gallery,
  not on paper.
- ⚖️ **MRU entry removal** (user: "probably need a right-click to remove
  things from the MRU as well. Well, maybe."). If it lands, it applies to
  file recents too, not just folders — a small shared-MRU affordance
  (macOS context menu; iOS long-press). Decide at pickup.
- ⚖️ Large-folder behavior: cap the listed children? lazy enumeration?
  (A shoot folder can hold hundreds of clips.) Decide at pickup; a simple
  cap + "N more…" is probably enough for v1.
- ⚖️ Folder-content freshness: re-enumerate on expand vs. watch the
  directory. Re-enumerate-on-expand is almost certainly enough.
