import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Iris

// MARK: - Test goal
//
// `ImageFrameDecoder` (M8·P2) is the seam that turns a still image into the same
// source-agnostic `Frame` capture and playback produce, so the existing detector
// + overlay pipeline runs on it unchanged. These tests pin the two things that
// can go wrong: the upright-`Frame` contract (dimensions, metadata, EXIF
// orientation baked in so `VideoGeometry` stays rotation-free), and that the
// decoded `Frame` is a valid input to a real `Detector`.

// MARK: - Fixtures (synthesized — no committed binary)

/// Build a `width`×`height` BGRA `CGImage`, optionally drawing into it. Mirrors
/// `VisionRectanglesDetectorTests.makeRectangleFrame`'s buffer setup but returns
/// a `CGImage` so it can feed the decoder (and be written to disk).
private func makeCGImage(
    width: Int,
    height: Int,
    draw: (CGContext) -> Void = { _ in }
) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo =
        CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue
    guard
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        )
    else {
        fatalError("CGContext creation failed")
    }
    // Black background by default.
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    draw(context)
    guard let image = context.makeImage() else {
        fatalError("CGContext.makeImage failed")
    }
    return image
}

/// Write `cgImage` to a temp PNG carrying `orientation` in its metadata, so the
/// from-URL path can be exercised against a real on-disk file with EXIF.
private func writeTempPNG(
    _ cgImage: CGImage,
    orientation: CGImagePropertyOrientation = .up
) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("iris-image-\(UUID().uuidString).png")
    let dest = try #require(
        CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil),
        "Failed to create image destination"
    )
    let props: [CFString: Any] = [kCGImagePropertyOrientation: orientation.rawValue]
    CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
    #expect(CGImageDestinationFinalize(dest), "PNG finalize failed")
    return url
}

// MARK: - Tests

@Suite struct ImageFrameDecoderTests {

    /// A `.up` image decodes to a `Frame` whose dimensions, source kind, format,
    /// orientation, and frozen timestamp all match the upright contract.
    @Test func decodesUprightFrameFromCGImage() throws {
        let image = makeCGImage(width: 200, height: 120)
        let decoder = ImageFrameDecoder()

        let frame = try decoder.frame(from: image, identifier: "shot.png")

        #expect(frame.dimensions == CGSize(width: 200, height: 120))
        #expect(frame.orientation == .up)
        #expect(frame.format == .bgra8)
        #expect(frame.timestamp == .zero)
        #expect(frame.source == .image("shot.png"))
        #expect(CVPixelBufferGetWidth(frame.pixelBuffer) == 200)
        #expect(CVPixelBufferGetHeight(frame.pixelBuffer) == 120)
    }

    /// A 90° EXIF orientation is **baked into the pixels** — the upright frame
    /// swaps width/height and is still stamped `.up`, so downstream geometry
    /// never has to rotate. This is the load-bearing correctness property.
    @Test func bakesNinetyDegreeOrientationToUprightDimensions() throws {
        let image = makeCGImage(width: 200, height: 120)
        let decoder = ImageFrameDecoder()

        // `.right` is a 90° rotation: upright dimensions transpose to 120×200.
        let frame = try decoder.frame(from: image, orientation: .right, identifier: "rotated")

        #expect(frame.dimensions == CGSize(width: 120, height: 200))
        #expect(frame.orientation == .up)
        #expect(CVPixelBufferGetWidth(frame.pixelBuffer) == 120)
        #expect(CVPixelBufferGetHeight(frame.pixelBuffer) == 200)
    }

    /// The from-URL path reads a real file via ImageIO and honors its embedded
    /// EXIF orientation, producing the same upright frame as the CGImage path.
    @Test func loadsFromDiskAndHonorsEmbeddedOrientation() throws {
        let image = makeCGImage(width: 200, height: 120)
        let url = try writeTempPNG(image, orientation: .right)
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = ImageFrameDecoder()

        let frame = try decoder.frame(fromImageAt: url)

        // Orientation baked from file metadata → transposed upright dimensions.
        #expect(frame.dimensions == CGSize(width: 120, height: 200))
        #expect(frame.orientation == .up)
        // Identifier defaults to the file name.
        #expect(frame.source == .image(url.lastPathComponent))
    }

    /// An unreadable URL surfaces a typed error rather than crashing.
    @Test func missingFileThrowsSourceUnreadable() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).png")
        let decoder = ImageFrameDecoder()

        #expect(throws: ImageFrameDecoder.DecodeError.self) {
            _ = try decoder.frame(fromImageAt: url)
        }
    }

    /// End-to-end: a decoded image `Frame` is a valid input to a real `Detector`.
    /// A high-contrast rectangle on the still is found by `VisionRectanglesDetector`
    /// — proving the BGRA/IOSurface buffer the decoder produces flows through the
    /// same Vision path capture/playback frames do. (Synthetic-rectangle Vision
    /// detection is already relied on by `VisionRectanglesDetectorTests`.)
    @Test func decodedImageFrameIsDetectableByVision() async throws {
        let width = 1280
        let height = 720
        // A centered white quad with clear margins — a clean rectangle target.
        let image = makeCGImage(width: width, height: height) { ctx in
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 340, y: 160, width: 600, height: 400))
        }
        let decoder = ImageFrameDecoder()
        let frame = try decoder.frame(from: image, identifier: "rect")

        let detector = VisionRectanglesDetector(maximumAspectRatio: 1.0)
        let detections = try await detector.detect(in: frame)

        #expect(!detections.isEmpty, "Expected the decoded image frame to yield a rectangle detection")
    }

    /// Plumbing check independent of any real model: a decoded frame runs through
    /// `DetectorPipeline` and returns the configured detector's output.
    @Test func decodedImageFrameRunsThroughPipeline() async throws {
        let image = makeCGImage(width: 64, height: 64)
        let decoder = ImageFrameDecoder()
        let frame = try decoder.frame(from: image, identifier: "plumbing")

        let canned = Detection(
            boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1),
            label: "mock",
            confidence: 1.0,
            sourceModelID: "mock-image"
        )
        let pipeline = DetectorPipeline(MockDetector(detections: [canned], modelIdentifier: "mock-image"))

        let out = try await pipeline.detect(in: frame)

        #expect(out.map(\.label) == ["mock"])
    }
}
