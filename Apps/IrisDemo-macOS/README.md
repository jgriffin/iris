# IrisDemo-macOS

M3 Phase 5 smoke-test app: file playback (`.mov` / `.mp4`) → Vision rectangle
detector → `ResultStore` → `DetectionLayer` overlay with `Scrubber` controls.
First end-to-end exercise of `PlayerLayerConverter`'s AVF side against a
live `AVPlayerLayer`. The whole app is two source files (this folder) plus
the `Iris` package as a local-path SwiftPM dependency.

## One-time setup (per clone)

The project uses an xcconfig override pattern to keep your Apple Developer
team ID out of git:

```bash
cp Apps/IrisDemo-macOS/Local.xcconfig.template Apps/IrisDemo-macOS/Local.xcconfig
```

Then edit `Local.xcconfig` and fill in two values:

- `DEVELOPMENT_TEAM` — find in Xcode → Settings → Accounts → select your
  Apple ID → "Team ID" column (10 alphanumeric characters).
- `PRODUCT_BUNDLE_IDENTIFIER` — a reverse-DNS bundle ID rooted at a domain
  you own or your team namespace; must be unique inside your team.

`Local.xcconfig` is gitignored. `Shared.xcconfig` (committed) does
`#include? "Local.xcconfig"` so build settings layer cleanly.

**Don't edit the Signing & Capabilities tab in Xcode** — those edits write
`DEVELOPMENT_TEAM` into `pbxproj` which IS committed. Edit `Local.xcconfig`
instead. If you slip and the team ID lands in `pbxproj`, run
`cd Apps && xcodegen generate` to rebuild it from the clean `project.yml`.

## Run

1. Open [`../IrisDemo.xcodeproj`](../IrisDemo.xcodeproj) in Xcode 26+.
2. Pick the **IrisDemo-macOS** scheme and **My Mac** as the run destination.
3. Hit Run. Click **Open Video…** and choose a `.mov` or `.mp4`.

## What to look for

- The video plays full-window with `videoGravity = .resizeAspect`
  letterbox/pillarbox bars where needed.
- A `Scrubber` at the bottom: drag to seek (frame-accurate), `<` / `>` to
  step one frame, play/pause toggle.
- Detection boxes drawn over the video, registered to subjects as playback
  progresses. Box positions should track during scrub + frame-step without
  drifting.
- Detection boxes disappear when the playback clock moves more than 2
  seconds past the last detection (the playback staleness threshold).

## Sandbox + entitlements

The app runs sandboxed with two entitlements:

- `com.apple.security.app-sandbox` (ON)
- `com.apple.security.files.user-selected.read-only`

The fileImporter API issues a security-scoped URL the app holds for the
session. `ContentView` acquires the scope on file pick and releases it on
teardown (window close, or new file pick). Files outside the user-selected
URL are not accessible — by design.

## Logging

The Console subsystem is `iris.demo`, category `phase5`. Filter by
`subsystem:iris.demo` to isolate the demo's log lines from system noise.
Frame-pipeline and AVF errors land under `iris.playback`.

## Regenerating the project

The `.xcodeproj` is generated from [`../project.yml`](../project.yml) by
[xcodegen](https://github.com/yonaskolb/XcodeGen). If you change project
settings (deployment target, capabilities, additional source folders),
edit `project.yml` and then run:

```bash
cd Apps && xcodegen generate
```

The generated `.xcodeproj` is checked in so contributors don't need
xcodegen installed just to open + run the demos. Install only when editing:
`brew install xcodegen`.
