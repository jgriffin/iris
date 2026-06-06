# Folder sources — pick a folder, browse it in the sidebar

<!-- M13 working plan: definition, settled forks, phases, opens. Status vocab
     per WORKFLOW.md. -->
_Captured · 2026-06-05 · picked up as **M13** 2026-06-05_ · **✅ shipped — merged to `main` 2026-06-05** (branch retired; smoke round 1 folded in: per-mode folder MRUs, double-duty open button, whole-row header taps)

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
- ✅ **P3 — Sidebar FOLDER block — designed in-canvas, wired.** Settled (user,
  from the `FolderBlockGallery` session): **FOLDERS below RECENT** (a picked
  child lands in RECENT up top anyway); folders expand **one-at-a-time**
  (animated, `.snappy` idiom; `.independent` deleted); **RECENT + FOLDERS each
  a collapsible sub-block** (reusing `SidebarSection`; supersedes M9·P6·4's
  caption-drop) with **item counts on every collapsible heading** incl.
  per-folder child counts; large-list handling deferred → BOARD §Backlog.
  Wired live: expand → re-enumerate under the folder's scope; child tap →
  `swapToExternal`/`pickImage` (RECENT promotion for free) + folder MRU
  promote; `folder.badge.plus` add button on the FOLDERS sub-header; children
  get a scoped-bookmark round trip minted under the parent's scope. Gallery
  pruned to the shipped design (regression surface).
- ✅ **P4 — Sequential pinned context headers + MRU entry removal.** Both
  user calls settled 2026-06-05: **sequential pinning** (native
  `LazyVStack(pinnedViews:)`, chosen over custom stacked dual-pin) — mode
  band ▸ RECENT ▸ FOLDERS ▸ open-folder row pin as you scroll, deepest
  replaces shallower, tap the pinned folder row to collapse/escape; required
  a full flatten of the active section into top-level Sections
  (`SidebarPinnedLayout.swift` is the one home for band tints / accent bar /
  opaque pinned underlays; `ModeSection` is preview-only now, live path =
  `ModeHeaderBand` + flattened `SourcesPanel`). **MRU removal IN** —
  `RecentBookmarks.remove(url:)` + context menus ("Remove from Recents" on
  RECENT rows, "Remove Folder" on folder rows, destructive w/ trash, never on
  children; animated out, counts update). Gallery reshaped to the flattened
  anatomy + a context-menu note case.

## Opens (close-out)

- ✅ **Hands-on smoke passed** (2026-06-05) — round 1 surfaced three fixes
  (per-mode folder MRUs · double-duty open button · whole-row header taps,
  see [DECISIONS.md](../DECISIONS.md)); re-smoke confirmed. Merged to `main`.
