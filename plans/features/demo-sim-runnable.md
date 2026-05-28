# Demo simulator-runnable — iOS demo on the iOS Simulator + Mac (Designed for iPad)

<!-- Working plan. Lifetime ~ this feature; LOG.md keeps the trail. Status vocab per WORKFLOW.md §"Status trees". -->
_Defined · 2026-05-27_ · **📋 P1–P4 planned**

## Scope / intent

Make the **iOS demo** ([`Apps/IrisDemo-iOS/`](../../Apps/IrisDemo-iOS/)) pleasant
to run where there's **no camera** — the iOS Simulator and **Mac (Designed for
iPad)** (the iPad-compat runtime on Apple Silicon, *not* the separate native
[`IrisDemo-macOS`](../../Apps/IrisDemo-macOS/) target, which is untouched here).
The blocker today isn't the build (device family is already iPhone+iPad,
`TARGETED_DEVICE_FAMILY = 1,2`) — it's that the app **opens on the Capture tab
and tries to start a camera that isn't there**, and there's no simple way to get
test videos onto the simulator.

Four changes, all confined to the iOS demo + repo tooling — **no `Sources/Iris/`
library changes**:

1. **Playback-first, sidebar layout.** Playback becomes the default tab and the
   tabs render as a left sidebar on iPad/Mac (bottom bar on iPhone).
2. **Camera fallback page.** When no camera is available (simulator / Mac),
   the Capture tab shows an info page instead of attempting to start a session —
   no failed-start error, no hang.
3. **File sharing.** Expose the app's Documents folder in the Files app so
   test videos can be dropped in and reached via the existing document picker.
4. **`just sim-add-video` helper.** One command to copy a video into the booted
   simulator's container.

This is **demo ergonomics, not core-library scope** — tracked as a feature on
branch `demo-sim-runnable`; **M7 — Dataset stays the milestone-path next**
([`DECISIONS.md`](../DECISIONS.md), per the 2026-05-27 tracking call).

## Decisions locked (2026-05-27)

- **Tab layout** → sidebar-adaptable `TabView` (`.tabViewStyle(.sidebarAdaptable)`),
  Playback default. Means migrating the demo's root `TabView` from the old
  `.tabItem` modifier to the iOS 18+ value-based `Tab(...)` API.
- **Sim videos** → enable file sharing (`UIFileSharingEnabled` +
  `LSSupportsOpeningDocumentsInPlace`) + a `just sim-add-video <path>` copy
  helper. Pick the dropped video via the existing `DocumentPicker`. **No** in-app
  Documents auto-discovery (not chosen — keeps the picker as the single entry).
- **Tracking** → feature plan + branch; not a milestone.

## Phases

### P1 — Playback-first sidebar layout
- [`Apps/IrisDemo-iOS/ContentView.swift:25–35`](../../Apps/IrisDemo-iOS/ContentView.swift) —
  rewrite the root `TabView` using the value-based `Tab("Playback", systemImage:)`/
  `Tab("Capture", systemImage:)` API, **Playback first**, and apply
  `.tabViewStyle(.sidebarAdaptable)`.
- Default selection follows tab order (Playback leftmost ⇒ default); add an
  explicit `selection` binding only if needed to force it.
- Verify on iPhone (bottom bar, Playback selected), iPad & Mac (left sidebar).

### P2 — Camera fallback page (no-camera detection)
- In `CaptureContentView` ([`ContentView.swift:49–163`](../../Apps/IrisDemo-iOS/ContentView.swift)),
  gate the `.task` that spawns `CaptureSession`: if **no video capture device is
  available**, skip the start entirely and render an info page.
- Detection: `AVCaptureDevice.default(for: .video) == nil` (true on simulator and
  Mac-Designed-for-iPad) — robust across both no-camera environments; covers
  `#if targetEnvironment(simulator)` plus `ProcessInfo.isiOSAppOnMac` in one
  runtime check. Camera still runs normally on a physical iPhone.
- Fallback page copy: e.g. *"Camera isn't available here — the Simulator and Mac
  (Designed for iPad) have no camera. Run on a physical iPhone to use Capture.
  Use the Playback tab to work with video files."* with a `play.rectangle` hint.
- "Don't get stuck": the page is purely informational; switching to Playback
  always works, and no session is ever started in the no-camera case.

### P3 — File sharing (Documents reachable in Files.app)
- [`Apps/IrisDemo-iOS/Info.plist`](../../Apps/IrisDemo-iOS/Info.plist) — add
  `UIFileSharingEnabled = true` and `LSSupportsOpeningDocumentsInPlace = true`.
  Surfaces the app's Documents folder under *Files → On My iPhone/iPad →
  IrisDemo*; the existing `DocumentPicker` can then browse to it.

### P4 — `just sim-add-video` helper + verify
- Create a repo-root `justfile` (none exists yet) with a `sim-add-video <path>`
  recipe:
  - Resolve bundle id by parsing `Apps/IrisDemo-iOS/Local.xcconfig`
    (`PRODUCT_BUNDLE_IDENTIFIER`) — per-developer, gitignored, so **not**
    hardcoded (`us.fofu.iris.demo` on this machine).
  - `xcrun simctl get_app_container booted <bundle-id> data` → copy the file
    into `…/Documents/`. Errors clearly if no sim is booted or the app isn't
    installed (must run/install once first).
- **Verify (hands-on):** iOS Simulator — launches to Playback; Capture tab shows
  the fallback page (no error/hang); `just sim-add-video <clip>` then Pick video
  → Files → On My iPhone → IrisDemo → clip plays. Repeat on **Mac (Designed for
  iPad)**. Plus `xcodebuild` iOS scheme green, strict-concurrency clean.

## Owns / out of scope

- **Owns:** iOS demo root layout, Capture-tab no-camera UX, iOS demo Info.plist
  file-sharing keys, the `justfile` helper.
- **Out:** `Sources/Iris/` library (no changes); the native `IrisDemo-macOS`
  target; in-app Documents auto-discovery (not chosen); MRU/security-scope flow
  (unchanged — picker still owns scope); fixing the camera *on* the simulator
  (impossible — there's no hardware).

## Opens / risks

- `.tabViewStyle(.sidebarAdaptable)` is iOS 18+; baseline is iOS 26 so it's
  available, but confirm the value-based `Tab` migration keeps the existing
  per-tab content/state intact (the Capture/Playback views are unchanged, only
  their host changes).
- `get_app_container` requires the app to be **installed on the booted sim**
  (run once from Xcode first) — the recipe should say so on failure.
- `LSSupportsOpeningDocumentsInPlace` changes open-in-place semantics for the
  picker; verify the existing security-scope balance still holds for in-place
  Documents files (they're already inside the app container, so scope is a
  no-op there).
