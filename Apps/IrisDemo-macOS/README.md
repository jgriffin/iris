# IrisDemo-macOS

The macOS build of the Iris demo. It's a **thin target** — the actual app is the
shared SwiftUI shell in [`../Shared/`](../Shared/), consumed here with the `Iris`
package as a local-path SwiftPM dependency. On macOS it exercises the library's
model-evaluation surface: pick a detector, tune it (global + per-class), play a
video, load an image, and flag frames for a dataset — all behind one
`NavigationSplitView` sidebar. **No camera capture on macOS** (that page is
iOS-only); the Mac is the playback / image / dataset-curation target.

See the [root README](../../README.md) for the library overview, and
[`../IrisDemo-iOS/README.md`](../IrisDemo-iOS/README.md) for the iOS build (same
shell, plus live capture).

## One-time setup (per clone)

An xcconfig override keeps your Apple Developer team ID out of git:

```bash
cp Apps/IrisDemo-macOS/Local.xcconfig.template Apps/IrisDemo-macOS/Local.xcconfig
```

Then edit `Local.xcconfig` and fill in:

- `DEVELOPMENT_TEAM` — Xcode → Settings → Accounts → your Apple ID → "Team ID"
  (10 alphanumeric characters).
- `PRODUCT_BUNDLE_IDENTIFIER` — a reverse-DNS bundle ID unique inside your team.

`Local.xcconfig` is gitignored. `Shared.xcconfig` (committed) does
`#include? "Local.xcconfig"`, so build settings layer cleanly and the project
still opens without it (signing just fails at build time).

**Don't edit the Signing & Capabilities tab in Xcode** — those edits write
`DEVELOPMENT_TEAM` into the `pbxproj` (which is committed). Edit `Local.xcconfig`
instead. If a team ID slips into the `pbxproj`, run `cd Apps && xcodegen generate`
to rebuild it from the clean `project.yml`.

## Run

1. Open [`../IrisDemo.xcodeproj`](../IrisDemo.xcodeproj) in Xcode 26+.
2. Pick the **IrisDemo-macOS** scheme and **My Mac** as the destination.
3. Run, then open a video or an image from the sidebar.

## Sandbox + entitlements

The app is sandboxed with `com.apple.security.app-sandbox` and
`com.apple.security.files.user-selected.read-only`. File pickers issue a
security-scoped URL the app holds for the session and releases on teardown;
files outside the user-selected URL are not accessible, by design.

## Regenerating the project

The `.xcodeproj` is generated from [`../project.yml`](../project.yml) by
[xcodegen](https://github.com/yonaskolb/XcodeGen) and **checked in**, so you only
need xcodegen when changing project settings:

```bash
cd Apps && xcodegen generate   # brew install xcodegen
```
