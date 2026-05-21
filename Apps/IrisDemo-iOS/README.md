# IrisDemo-iOS

M1 smoke-test app: live `CameraPreview` + a `for await` loop logging frame
timestamps to `os.Logger`. The whole app is two source files (this folder)
plus the `Iris` package as a local-path SwiftPM dependency.

## One-time setup in Xcode

Create the Xcode project so it co-locates with these sources:

1. **File → New → Project… → iOS → App.**
2. **Product Name:** `IrisDemo-iOS`. **Interface:** SwiftUI. **Language:** Swift.
   **Bundle Identifier:** anything (e.g. `com.<you>.iris.demo`). Save the
   project at the **repo root** (`iris/Apps/`); Xcode will create
   `iris/Apps/IrisDemo-iOS.xcodeproj` and an `iris/Apps/IrisDemo-iOS/` source
   folder. Delete the auto-generated files Xcode put inside that source folder
   (`IrisDemo_iOSApp.swift`, `ContentView.swift`, `Assets.xcassets`,
   `Preview Content/`) — **the pre-written files in this directory replace
   them** and have the same target membership once Xcode picks them up.
3. **Target settings → General → Minimum Deployments:** iOS 26.0.
4. **Target settings → Info:** confirm `NSCameraUsageDescription` is set
   (Xcode reads it from `Info.plist` if you wire the build setting
   `INFOPLIST_FILE` to point at `IrisDemo-iOS/Info.plist`, OR you can add the
   key inline via the Info tab and ignore the provided `Info.plist`).
5. **File → Add Package Dependencies… → Add Local…** Pick the repo root
   (`iris/`). Add the `Iris` library to the IrisDemo-iOS target.
6. **Make sure the source files in this directory are members of the
   IrisDemo-iOS target** (Xcode usually auto-adds files dragged into the
   project navigator; confirm in the Inspector).

Then **Run on a physical iPhone (iOS 26+).** The simulator has no camera
hardware — the demo will surface `noDeviceAvailable` or `permissionDenied`
there. That's expected.

## What to look for

- Full-screen live preview in the correct orientation.
- Rotating the device re-orients the preview without jank.
- Xcode's Console emits `frame ts=<seconds> size=<w>x<h>` at ~30 Hz with
  monotonically increasing timestamps.

The Console subsystem is `iris.demo`, category `capture`. Filter by
`subsystem:iris.demo` to isolate the demo's log lines from system noise.
