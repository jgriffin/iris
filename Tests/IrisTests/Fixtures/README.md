# Test fixtures

Real-world media used by `IrisTests`. The point of fixtures (vs. synthetic
inputs) is to exercise detectors and source adapters against the same kinds
of pixel buffers they'll see in production — Vision's behavior on a hand-drawn
`CGContext` rectangle and on actual H.264-decoded frames is not identical, so
both shapes get coverage.

## Storage: Git LFS

Anything in this folder matching the patterns in [`.gitattributes`](../../../.gitattributes)
is stored via Git LFS, not in regular git object storage. Currently tracked
extensions:

```
Tests/IrisTests/Fixtures/*.mov
Tests/IrisTests/Fixtures/*.mp4
Tests/IrisTests/Fixtures/*.mlmodel
Tests/IrisTests/Fixtures/*.mlpackage/**
Tests/IrisTests/Fixtures/*.png
```

Run `git lfs install` once after cloning the repo; otherwise the files in
this folder will check out as pointer text rather than real binaries and
the fixture-based tests will fail to open them.

To verify a new fixture is actually under LFS after staging:

```
git lfs ls-files
```

The file should be listed. If it isn't, the `.gitattributes` pattern isn't
catching it — add the extension there before committing.

## Files

### `clipboard-blank-page.mp4`

- **Source:** https://www.pexels.com/video/blank-page-on-a-clipboard-6787196/
- **Pexels video ID:** 6787196
- **Author:** Artem Podrez
- **License:** [Pexels License](https://www.pexels.com/license/) — free for
  commercial and non-commercial use, no attribution required, no
  redistribution as stock. Embedding in a Swift package's unit-test fixture
  is within the license's intended use.
- **Resolution:** 1280 x 720
- **Duration:** ~9.5 s (284 frames @ 30 fps, H.264)
- **File size:** 3.0 MB
- **Used by:** `Tests/IrisTests/Detection/VisionRectanglesDetectorFixtureTests.swift`
  — a blank sheet of paper on a clipboard against a contrasting background
  provides a high-confidence rectangle target for `VisionRectanglesDetector`.
  The test pulls a handful of frames via `AVAssetReader` and asserts that
  detections fire on the majority of them.

### `dancer-full-body.mp4`

- **Source:** https://www.pexels.com/video/dancing-woman-6616343/
- **Pexels video ID:** 6616343
- **Author:** Yan Krukau
- **License:** [Pexels License](https://www.pexels.com/license/) — free for
  commercial and non-commercial use, no attribution required, no
  redistribution as stock. Embedding in a Swift package's unit-test fixture
  is within the license's intended use.
- **Resolution:** 1280 x 720
- **Duration:** ~24.8 s (619 frames @ 25 fps, H.264)
- **File size:** 7.9 MB
- **Used by:** `Tests/IrisTests/Detection/VisionBodyPoseDetectorFixtureTests.swift`
  — a single dancer, full body head-to-feet, clearly lit against a plain
  draped studio backdrop with no clutter or other people, and dynamic poses
  that spread the limbs out — a high-detectability target for Apple Vision's
  2D body-pose request. The test pulls a handful of frames via `AVAssetReader`
  and asserts that a body pose with a reasonable joint count is detected on
  the majority of them.
