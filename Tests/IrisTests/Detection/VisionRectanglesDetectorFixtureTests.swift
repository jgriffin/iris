import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Testing

@testable import Iris

// MARK: - Fixture decoder

/// Decode up to `maximumFrames` BGRA pixel buffers from a fixture clip and
/// wrap each one in a `Frame`. Backed by `AVAssetReader` so the test stays
/// hermetic — no `AVPlayer`, no display loop, no UI dependency. Available
/// on both iOS and macOS (the only place `AVAssetReader` is unavailable is
/// the Vision Pro simulator, which Iris doesn't target).
///
/// Decoded frames carry their natural presentation timestamps and a
/// `.up` orientation tag. The clip is shot upright so no rotation metadata
/// matters for the rectangles assertion.
private func decodeFrames(
    from url: URL,
    maximumFrames: Int
) async throws -> [Frame] {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    guard let track = tracks.first else {
        Issue.record("Fixture has no video track: \(url.lastPathComponent)")
        return []
    }

    let (naturalSize, _) = try await track.load(.naturalSize, .preferredTransform)

    let reader = try AVAssetReader(asset: asset)
    let outputSettings: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
    ]
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else {
        Issue.record("AVAssetReader rejected BGRA output settings")
        return []
    }
    reader.add(output)

    guard reader.startReading() else {
        let message = reader.error?.localizedDescription ?? "unknown"
        Issue.record("AVAssetReader failed to start: \(message)")
        return []
    }

    var frames: [Frame] = []
    frames.reserveCapacity(maximumFrames)

    while frames.count < maximumFrames, let sample = output.copyNextSampleBuffer() {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        frames.append(
            Frame(
                pixelBuffer: pixelBuffer,
                timestamp: pts,
                orientation: .up,
                source: .mock("fixture:\(url.lastPathComponent)"),
                format: .bgra8,
                dimensions: naturalSize
            )
        )
    }

    return frames
}

// MARK: - Tests

@Test
func visionRectanglesDetectorFiresOnFixtureClip() async throws {
    // Resolved through `Bundle.module`, which the SwiftPM build emits
    // because `Package.swift` declares `resources: [.process("Fixtures")]`
    // on the test target.
    let url = try #require(
        Bundle.module.url(forResource: "clipboard-blank-page", withExtension: "mp4"),
        """
        Missing fixture clipboard-blank-page.mp4 — \
        run `git lfs install && git lfs pull` after clone.
        """
    )

    // 10 frames keeps the test fast (well under a second of decoded
    // video) while still averaging detector behavior across motion and
    // small framing changes. The clip is ~9.5s at 30 fps; the first 10
    // frames cover the opening third-of-a-second where the clipboard is
    // in shot from frame zero.
    let frames = try await decodeFrames(from: url, maximumFrames: 10)
    #expect(frames.count == 10, "Expected to decode 10 frames, got \(frames.count)")

    // `maximumAspectRatio: 1.0` to accept the clipboard's near-portrait
    // proportions (Vision's default of 0.5 is the *minimum* allowed,
    // i.e., narrow) — same footgun resolved in the hermetic test above.
    // `minimumSize: 0.1` because the clipboard occupies more than 10% of
    // the shortest image dimension but the page itself may not always
    // hit Vision's default 0.2 floor at frame edges.
    let detector = VisionRectanglesDetector(
        minimumAspectRatio: 0.3,
        maximumAspectRatio: 1.0,
        minimumSize: 0.1
    )

    // Run detection on each frame. Sequential rather than parallel —
    // Vision serializes its own work and parallel dispatch buys nothing
    // for a 10-frame smoke. Sequential keeps the failure mode legible.
    var framesWithDetection = 0
    for frame in frames {
        let detections = try await detector.detect(in: frame)
        let strong = detections.filter { $0.confidence >= 0.5 }
        if !strong.isEmpty { framesWithDetection += 1 }
    }

    // Threshold: at least 5 of 10 frames yield a rectangle with
    // confidence >= 0.5. Empirically the clip hits much higher than
    // this — the loose floor keeps the test deterministic across
    // Vision-revision bumps without becoming a no-op assertion.
    #expect(
        framesWithDetection >= 5,
        "Vision found rectangles on only \(framesWithDetection)/\(frames.count) fixture frames"
    )
}
