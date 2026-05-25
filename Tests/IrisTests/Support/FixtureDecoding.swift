import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import Iris

/// Decode up to `maximumFrames` BGRA pixel buffers from a fixture clip and
/// wrap each one in a `Frame`. Backed by `AVAssetReader` so tests stay
/// hermetic — no `AVPlayer`, no display loop, no UI dependency. Available
/// on both iOS and macOS (the only place `AVAssetReader` is unavailable is
/// the Vision Pro simulator, which Iris doesn't target).
///
/// Decoded frames carry their natural presentation timestamps and a `.up`
/// orientation tag. Fixture clips are shot upright so no rotation metadata
/// matters for detector assertions.
///
/// Shared between the Vision detector fixture tests (rectangles, body pose)
/// — a single source of truth for the decode scaffolding.
func decodeFrames(
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
