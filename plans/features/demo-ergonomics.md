# Demo ergonomics — file picker + MRU

**Scope.** Pure demo-side polish. No library API changes. Two affordances the user flagged on 2026-05-22 during the [playback-detection-cache](./playback-detection-cache.md) work block:

1. **iOS Playback tab needs a file picker.** Today's Playback tab hard-codes the bundled `clipboard-blank-page.mp4` fixture (M3 Phase 6) — fine for the M3 close-out smoke, painful for ongoing iteration when you want to try other clips.
2. **Both demos need MRU.** macOS uses `NSOpenPanel`; iOS will gain `UIDocumentPickerViewController`. Both currently force re-traversal of the file picker every launch. Persist a recent-files list backed by `UserDefaults` + security-scoped bookmarks so a tap re-opens recent clips.

**Why now:** Future feature work (Phase 1 of every subsequent library-side feature will want device + Mac smoke against multiple clips) is held back by ergonomic friction. Knock it out before opening M4 (`IrisTuning`).

**Why not in the Iris library:** This is consumer-app concern. The Iris package's public surface (`PlaybackSource`, `PlaybackView`, `Scrubber`, etc.) already takes a URL — picking the URL and remembering recent ones is the consumer's job. Bundling MRU into the library would couple it to `UserDefaults` and to a UI shape that consumers may not want.

## Public surface

None. All artifacts land under `Apps/IrisDemo-iOS/` and `Apps/IrisDemo-macOS/`.

Shared model (likely `Apps/Shared/` or duplicated per-target — decide during execution):

- `RecentVideos` — `@Observable` model holding the MRU list. Backed by `UserDefaults` (key `"iris.recent.videos.v1"`). Stores security-scoped bookmark data (cross-launch), not raw URLs. Limit ~10 entries. `addOrPromote(_ url: URL)`, `resolve() -> [URL]` (drops stale entries that fail to resolve), `clear()`.

Per-target views:

- **iOS:** `PlaybackContentView` (currently bundled-fixture only) gains a file-picker affordance — a "Pick video" button that presents `UIDocumentPickerViewController` (`.movie` types) via `UIViewControllerRepresentable`, plus an MRU list (latest-first, tap to open). The bundled fixture stays as a fallback / first-launch default.
- **macOS:** `ContentView` already shows `NSOpenPanel`; gains an MRU list rendered in a sidebar or menu. Same `RecentVideos` model.

## Phases

### Phase 1 — `RecentVideos` model + UserDefaults storage

Shared `RecentVideos` `@Observable` class. Methods: `addOrPromote(_ url: URL)` (creates a security-scoped bookmark, prepends to list, trims to ~10), `resolve() -> [URL]` (resolves bookmarks back to URLs, drops any that fail with `isStale == true` or throw, returns the valid set in MRU order), `clear()`. Storage shape on disk: `Data` array of bookmark blobs serialized via `JSONEncoder`. iOS bookmarks use `URL.bookmarkData()` with `[.minimalBookmark]`; macOS uses `[.withSecurityScope, .securityScopeAllowOnlyReadAccess]` (the demo target's sandbox entitlement is already `files.user-selected.read-only`).

Unit tests against a `UserDefaults` instance scoped to a test suite name (so the test doesn't clobber a real user's MRU). Coverage: empty default, add-and-promote semantics (second add of the same URL moves it to front, doesn't duplicate), trim-to-limit, clear, stale-bookmark filtering on resolve.

**Cross-platform shape:** the model is platform-agnostic, but the bookmark *flags* differ (security scope on macOS, plain bookmark on iOS). Use `#if os(macOS)` for the flag set inside `addOrPromote`. Public API of `RecentVideos` is platform-uniform.

### Phase 2 — iOS file picker + Playback tab integration

`Apps/IrisDemo-iOS/`: `PlaybackContentView` gains a "Pick video" button that presents `UIDocumentPickerViewController(forOpeningContentTypes: [.movie])` via a `UIViewControllerRepresentable`. On pick: call `url.startAccessingSecurityScopedResource()`, hand to `PlaybackController(url:)`, register in `RecentVideos`, balance `stopAccessing` on teardown (mirror the existing macOS pattern from M3 Phase 5). Bundled fixture remains as default if no MRU + no pick happened yet.

MRU list rendered as a SwiftUI `List` below the player (or in a sidebar — execution decides). Tap an MRU row → resolve bookmark → swap the controller's source. Long-press / swipe to remove a single entry. Empty-list state: "Pick a video to start" affordance pointing at the picker button.

### Phase 3 — macOS MRU integration

`Apps/IrisDemo-macOS/`: existing `NSOpenPanel` flow stays; on pick, register in `RecentVideos`. Add an MRU sidebar or `Menu` (likely sidebar — matches Files-app-style ergonomics). Tap to swap source. Mirror the security-scope start/stop pattern already used in M3 Phase 5's `ContentView.swift`.

## Risks

- **Bookmark resolution failures across reboots / file moves.** A bookmark can go stale if the user moves or deletes the underlying file. `RecentVideos.resolve()` filters these silently; UI should surface "stale entry dropped" feedback only if the user tapped a stale entry directly (otherwise it's noise on launch). Use the `bookmarkDataIsStale` outparam to optionally refresh in place.
- **Security-scope accounting under tab switches.** iOS Playback tab teardown (the M3 polish fix `98eb4bc`) already invalidates the `PlaybackSource` on tab change. Tab-switch needs to *also* balance `stopAccessingSecurityScopedResource` — losing this gives sandbox leaks. Phase 2 must preserve the M3 teardown pattern and extend it.
- **UserDefaults concurrency.** `UserDefaults.standard` is thread-safe for reads/writes but ordering with `@Observable` publishes wants attention. Probably fine since the model writes from `@MainActor`; verify under Swift 6 strict concurrency.
- **Cross-target `RecentVideos` placement.** SwiftPM-package source under `Apps/Shared/` would need both demo targets to compile it; xcodegen `project.yml` already has the two-target shape but may need a shared sources entry. Alternative: duplicate the type per-target (cheap, ~80 lines). Decide during execution; lean toward shared.

## Exit criteria

- iOS Playback tab: "Pick video" button works, MRU list appears below the player, tap-to-open swaps the source. Bundled fixture remains as first-launch default.
- macOS demo: existing `NSOpenPanel` flow unchanged, plus MRU sidebar/menu showing recent picks with tap-to-open.
- Both demos: MRU persists across app relaunches; stale bookmarks silently filtered on resolve.
- No library API changes — `git diff Sources/Iris/` is empty.
- All public types compile under Swift 6 strict concurrency on both platforms. `swift test` green; both demo `xcodebuild` targets green.
- Manual smoke: pick a clip, quit the app, relaunch, the MRU shows it. Tap → opens. Move the underlying file, relaunch, the entry disappears (no crash, no error dialog).
