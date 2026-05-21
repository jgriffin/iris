# ``Iris``

Shared scaffolding for camera + ML vision apps on Apple platforms.

## Overview

Iris is a Swift package that handles the recurring plumbing — capture,
playback, ML inference, overlays, dataset capture — so individual projects
can focus on their specific detection problem. Every new vision app
otherwise repeats the same wiring: AVFoundation capture, preview layers,
frame extraction, Vision/Core ML inference, drawing bounding boxes,
swapping models, tuning thresholds. Iris is that shared foundation.

The package ships as a single SwiftPM target with one umbrella product.
Components are organized as folders under `Sources/Iris/` — `Capture/` is
iOS-only (file-level `#if os(iOS)` gating); `Playback/`, `Detection/`, and
`Overlay/` work on both iOS 26+ and macOS 26+. `Tuning/` and `Dataset/`
arrive in later milestones.

## Topics

### Capture

Live camera feed on iOS via `AVCaptureSession`, exposed as an
`AsyncStream<Frame>` plus a SwiftUI preview view.
