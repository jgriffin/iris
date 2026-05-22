import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import Testing

@testable import Iris

// MARK: - Helpers

/// Build an IOSurface-backed BGRA `CVPixelBuffer` and draw a white
/// rectangle on a black background using CoreGraphics, then wrap it in a
/// `Frame`. Used as a hermetic input for the Vision rectangles adapter so
/// the test doesn't depend on any LFS fixture.
private func makeRectangleFrame(
    rect: CGRect,
    width: Int = 1280,
    height: Int = 720,
    timestamp: CMTime = CMTime(value: 1, timescale: 60)
) -> Frame {
    let attrs: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
    ]
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        attrs as CFDictionary,
        &buffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer = buffer else {
        fatalError("CVPixelBufferCreate failed with status \(status)")
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
        fatalError("CVPixelBufferGetBaseAddress returned nil")
    }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo =
        CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue
    guard
        let context = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        )
    else {
        fatalError("CGContext creation failed")
    }

    // Black background.
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // White rectangle. Inset slightly with a thin black inner border so
    // there's clean contrast on all four edges — Vision's rectangle
    // detector keys on high-contrast quadrilateral edges, not on filled
    // blobs. Without the inner stroke the white fill butts directly
    // against the frame boundary and the detector underperforms.
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(rect)

    return Frame(
        pixelBuffer: pixelBuffer,
        timestamp: timestamp,
        orientation: .up,
        source: .mock("vision-rectangles-tests"),
        format: .bgra8,
        dimensions: CGSize(width: width, height: height)
    )
}

// MARK: - Tests

@Test
func visionRectanglesDetectorAdvertisesAvailableAndStableIdentifier() {
    let detector = VisionRectanglesDetector()
    #expect(detector.availability == .available)
    #expect(detector.modelIdentifier == "vision.rectangles")
}

@Test
func visionRectanglesDetectorFindsHighContrastRectangle() async throws {
    // Centered white rect filling most of the frame, well within Vision's
    // default minimumSize / aspect-ratio bounds.
    let width = 1280
    let height = 720
    let rect = CGRect(x: 200, y: 120, width: 880, height: 480)
    let frame = makeRectangleFrame(rect: rect, width: width, height: height)

    // Accept squares too (default maximumAspectRatio of 0.5 is narrow);
    // keep other defaults — Vision will pick this rect up cleanly.
    let detector = VisionRectanglesDetector(maximumAspectRatio: 1.0)
    let detections = try await detector.detect(in: frame)

    #expect(!detections.isEmpty, "Expected at least one rectangle detection")
    guard let best = detections.max(by: { $0.confidence < $1.confidence }) else {
        Issue.record("No detections returned")
        return
    }

    #expect(best.label == "rectangle")
    #expect(best.sourceModelID == "vision.rectangles")
    #expect(best.confidence > 0.5, "Confidence below 0.5: \(best.confidence)")

    // Expected bbox in Vision-native normalized coordinates (origin
    // bottom-left). Drawn-rect Y in image-coords is 120; Vision flips so
    // the bbox's y is (height - drawnY - drawnH) / height.
    let expectedX = CGFloat(rect.minX) / CGFloat(width)
    let expectedW = rect.width / CGFloat(width)
    let expectedH = rect.height / CGFloat(height)
    let expectedY = (CGFloat(height) - rect.minY - rect.height) / CGFloat(height)

    let tolerance: CGFloat = 0.05
    #expect(
        abs(best.boundingBox.minX - expectedX) < tolerance,
        "x off: \(best.boundingBox.minX) vs \(expectedX)"
    )
    #expect(
        abs(best.boundingBox.minY - expectedY) < tolerance,
        "y off: \(best.boundingBox.minY) vs \(expectedY)"
    )
    #expect(
        abs(best.boundingBox.width - expectedW) < tolerance,
        "w off: \(best.boundingBox.width) vs \(expectedW)"
    )
    #expect(
        abs(best.boundingBox.height - expectedH) < tolerance,
        "h off: \(best.boundingBox.height) vs \(expectedH)"
    )

    // Four keypoints in documented order: topLeft, topRight,
    // bottomRight, bottomLeft.
    let kps = try #require(best.keypoints)
    #expect(kps.count == 4)
    #expect(kps.map(\.name) == ["topLeft", "topRight", "bottomRight", "bottomLeft"])
}

@Test
func detectorPipelineRunsAllDetectorsAndConcatenatesInInputOrder() async throws {
    let rect = CGRect(x: 200, y: 120, width: 880, height: 480)
    let frame = makeRectangleFrame(rect: rect)

    let mockDetection = Detection(
        boundingBox: CGRect(x: 0.01, y: 0.02, width: 0.03, height: 0.04),
        label: "mock",
        confidence: 0.42,
        sourceModelID: "mock-pipeline"
    )
    let mock = MockDetector(detections: [mockDetection], modelIdentifier: "mock-pipeline")
    let vision = VisionRectanglesDetector(maximumAspectRatio: 1.0)

    let pipeline = DetectorPipeline(vision, mock)
    let combined = try await pipeline.detect(in: frame)

    // The Vision detector returns >= 1 rectangle; mock returns exactly 1.
    // Combined output should contain both kinds of detections.
    let hasRectangle = combined.contains { $0.label == "rectangle" }
    let hasMock = combined.contains { $0.label == "mock" }
    #expect(hasRectangle, "Vision rectangle detection missing from pipeline output")
    #expect(hasMock, "Mock detection missing from pipeline output")

    // Input order: vision first, mock second. So the LAST element of the
    // concatenation should be the mock entry — order is documented as
    // stable per detectors-supplied-to-init.
    #expect(combined.last?.label == "mock")
    #expect(combined.last?.sourceModelID == "mock-pipeline")
}

@Test
func detectorPipelineVariadicAndArrayInitsAreEquivalent() async throws {
    let mockA = MockDetector(
        detections: [
            Detection(
                boundingBox: .zero, label: "a", confidence: 1.0, sourceModelID: "a"
            )
        ],
        modelIdentifier: "a"
    )
    let mockB = MockDetector(
        detections: [
            Detection(
                boundingBox: .zero, label: "b", confidence: 1.0, sourceModelID: "b"
            )
        ],
        modelIdentifier: "b"
    )

    let pipelineVariadic = DetectorPipeline(mockA, mockB)
    let pipelineArray = DetectorPipeline([mockA, mockB])

    // Use the synthetic helper for a real frame, even though the mocks
    // don't read it — keeps the call signature exercised.
    let frame = makeRectangleFrame(rect: CGRect(x: 0, y: 0, width: 10, height: 10))
    let variadicOut = try await pipelineVariadic.detect(in: frame)
    let arrayOut = try await pipelineArray.detect(in: frame)

    #expect(variadicOut == arrayOut)
    #expect(variadicOut.map(\.label) == ["a", "b"])
}
