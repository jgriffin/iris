# Iris

Swift package providing the shared scaffolding for camera + ML vision apps on
Apple platforms: capture, playback, inference, overlays, tuning, and dataset
capture. Downstream projects depend on Iris and focus on their specific
detection problem.

## Setup

```bash
git clone <repo-url> iris
cd iris

# One-time per machine: install Git LFS so fixtures materialize.
brew install git-lfs
git lfs install

# One-time per clone: wire the project's pre-commit hook.
git config core.hooksPath .githooks
```

Then `swift build` from the repo root, or open `Package.swift` in Xcode.

## Demo app

The iOS demo lives at `Apps/IrisDemo-iOS/` and consumes Iris as a local-path
SwiftPM dependency. It will be created at M1 phase 5; open
`Apps/IrisDemo-iOS.xcodeproj` in Xcode 26+ and run on a physical iPhone
(iOS 26+) to see live preview + frame-timestamp logging.

## Planning

Design intent, milestones, decisions, and open questions live under `plans/`.
Start with [`plans/BRIEF.md`](./plans/BRIEF.md).
