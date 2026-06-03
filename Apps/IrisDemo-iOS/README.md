# IrisDemo-iOS

The iOS build of the Iris demo. It's a **thin target** — the actual app is the
shared SwiftUI shell in [`../Shared/`](../Shared/), consumed here with the `Iris`
package as a local-path SwiftPM dependency. On iOS it exercises the full library:
pick a detector, tune it (global + per-class), play a video, load an image, run
the **live camera**, and flag frames for a dataset — all behind one
`NavigationSplitView` sidebar.

See the [root README](../../README.md) for the library overview. The macOS build
shares all of this code minus camera capture — see
[`../IrisDemo-macOS/README.md`](../IrisDemo-macOS/README.md).

## One-time setup (per clone)

An xcconfig override keeps your Apple Developer team ID out of git:

```bash
cp Apps/IrisDemo-iOS/Local.xcconfig.template Apps/IrisDemo-iOS/Local.xcconfig
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
2. Pick the **IrisDemo-iOS** scheme.
3. For **live capture**, run on a physical iPhone (iOS 26+) — the simulator has
   no camera, so the capture page surfaces an unavailable state there. **Playback
   and image** modes work fine in the simulator.

To drop a test video into the booted simulator's Documents folder (for the file
picker): `just sim-add-video <path>` from the repo root.

## Regenerating the project

The `.xcodeproj` is generated from [`../project.yml`](../project.yml) by
[xcodegen](https://github.com/yonaskolb/XcodeGen) and **checked in**, so you only
need xcodegen when changing project settings:

```bash
cd Apps && xcodegen generate   # brew install xcodegen
```
