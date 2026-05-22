import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import Testing

@testable import Iris

// MARK: - Helpers

/// Build an IOSurface-backed YUV-420 bi-planar `CVPixelBuffer` and wrap it
/// in a `Frame`. No AVF needed; satisfies the `Frame` `@unchecked Sendable`
/// invariants (immutable + IOSurface-backed) so the synthesized frame can
/// cross the `Detector` actor boundary without complaint.
private func makeSyntheticFrame(
    timestamp: CMTime = CMTime(value: 1, timescale: 60),
    width: Int = 320,
    height: Int = 240
) -> Frame {
    let attrs: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
    ]
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        attrs as CFDictionary,
        &buffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer = buffer else {
        fatalError("CVPixelBufferCreate failed with status \(status)")
    }
    return Frame(
        pixelBuffer: pixelBuffer,
        timestamp: timestamp,
        orientation: .up,
        source: .mock("detector-tests"),
        format: .yuv420BiPlanarFull,
        dimensions: CGSize(width: width, height: height)
    )
}

// MARK: - Tests

@Test
func mockDetectorReturnsConfiguredDetections() async throws {
    let detections = [
        Detection(
            boundingBox: CGRect(x: 0.10, y: 0.20, width: 0.30, height: 0.40),
            label: "face",
            confidence: 0.91,
            sourceModelID: "mock"
        ),
        Detection(
            boundingBox: CGRect(x: 0.50, y: 0.50, width: 0.20, height: 0.20),
            label: "face",
            confidence: 0.72,
            sourceModelID: "mock"
        ),
    ]
    let detector = MockDetector(detections: detections, modelIdentifier: "mock-faces")

    #expect(detector.availability == .available)
    #expect(detector.modelIdentifier == "mock-faces")

    await detector.prewarm()
    let frame = makeSyntheticFrame()
    let result = try await detector.detect(in: frame)

    #expect(result == detections)
}

@Test
func mockDetectorEmptyConfigurationReturnsEmptyArray() async throws {
    // Distinguishing "detector ran and found nothing" (== []) from "no
    // detector ran" is a load-bearing distinction (see Detection.swift
    // doc). Confirm the empty path round-trips as an empty array, not nil.
    let detector = MockDetector()
    let result = try await detector.detect(in: makeSyntheticFrame())
    #expect(result.isEmpty)
}

@Test
func mockDetectorRespectsConfiguredAvailability() {
    let detector = MockDetector(availability: .modelNotReady)
    #expect(detector.availability == .modelNotReady)
}
