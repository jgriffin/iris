# IrisDemo-iOS

M1 smoke-test app: live `CameraPreview` + a `for await` loop logging frame
timestamps to `os.Logger`. The whole app is two source files (this folder)
plus the `Iris` package as a local-path SwiftPM dependency.

## One-time setup (per clone)

The project uses an xcconfig override pattern to keep your Apple Developer
team ID out of git:

```bash
cp Apps/IrisDemo-iOS/Local.xcconfig.template Apps/IrisDemo-iOS/Local.xcconfig
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

1. Open [`../IrisDemo-iOS.xcodeproj`](../IrisDemo-iOS.xcodeproj) in Xcode 26+.
2. Pick your physical iPhone as the run destination (the simulator has no
   camera hardware — the demo will surface `noDeviceAvailable` there).
3. Hit Run. First launch prompts for camera permission.

## What to look for

- Full-screen live preview in the correct orientation.
- Rotating the device re-orients the preview without jank.
- Xcode's Console emits `frame ts=<seconds> size=<w>x<h>` at ~30 Hz with
  monotonically increasing timestamps.

The Console subsystem is `iris.demo`, category `capture`. Filter by
`subsystem:iris.demo` to isolate the demo's log lines from system noise.

## Regenerating the project

The `.xcodeproj` is generated from [`../project.yml`](../project.yml) by
[xcodegen](https://github.com/yonaskolb/XcodeGen). If you change project
settings (deployment target, capabilities, additional source folders),
edit `project.yml` and then run:

```bash
cd Apps && xcodegen generate
```

The generated `.xcodeproj` is checked in so contributors don't need
xcodegen installed just to open + run the demo. Install only when editing:
`brew install xcodegen`.
