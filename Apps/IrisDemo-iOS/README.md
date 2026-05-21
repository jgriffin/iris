# IrisDemo-iOS

M1 smoke-test app: live `CameraPreview` + a `for await` loop logging frame
timestamps to `os.Logger`. The whole app is two source files (this folder)
plus the `Iris` package as a local-path SwiftPM dependency.

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
