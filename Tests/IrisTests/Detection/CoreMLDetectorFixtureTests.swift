import CoreML
import Foundation
import Testing

@testable import Iris

/// Fixture test for `CoreMLDetector` + `VisionObjectDecoder` (path A) against
/// the converted YOLOv12n model and a real clip.
///
/// The model fixture (`yolo12n.mlpackage`, 80 COCO labels, an Apple
/// `NonMaximumSuppression` pipeline) lives under `Tests/.../Fixtures/` tracked
/// via Git LFS. It's compiled to an `.mlmodelc` at runtime via
/// `CoreMLModelLoading.compileAndLoad(at:)` — Iris never commits a compiled
/// model. The clip is the same `dancer-full-body.mp4` the body-pose test uses;
/// it has a person on screen, so YOLO should emit a `"person"` detection.
///
/// Mirrors `VisionBodyPoseDetectorFixtureTests` in shape: shared
/// `decodeFrames`, an LFS guard via `#require`, ~10 frames, loose floors for
/// determinism across Core ML / Vision revision bumps.
@Test
func coreMLDetectorDetectsPersonOnDancerClip() async throws {
    let modelURL = try #require(
        Bundle.module.url(forResource: "yolo12n", withExtension: "mlpackage"),
        """
        Missing fixture yolo12n.mlpackage — \
        run `git lfs install && git lfs pull` after clone.
        """
    )
    let clipURL = try #require(
        Bundle.module.url(forResource: "dancer-full-body", withExtension: "mp4"),
        """
        Missing fixture dancer-full-body.mp4 — \
        run `git lfs install && git lfs pull` after clone.
        """
    )

    let model = try await CoreMLModelLoading.compileAndLoad(at: modelURL)
    let detector = try CoreMLDetector(
        model: model,
        decoder: VisionObjectDecoder(),
        modelIdentifier: "coreml.yolo12n"
    )

    let frames = try await decodeFrames(from: clipURL, maximumFrames: 10)
    #expect(frames.count == 10, "Expected to decode 10 frames, got \(frames.count)")

    var totalDetections = 0
    var sawPerson = false
    var sampleDetection: Detection?
    var labelsSeen: Set<String> = []

    for frame in frames {
        let detections = try await detector.detect(in: frame)
        totalDetections += detections.count
        for d in detections {
            labelsSeen.insert(d.label)
            if d.label == "person" {
                sawPerson = true
                sampleDetection = sampleDetection ?? d
            }
        }
        // Hold onto *some* detection even if no person appears on a given
        // frame, so the box/confidence assertions have a subject.
        sampleDetection = sampleDetection ?? detections.first
    }

    #expect(
        totalDetections >= 1,
        "YOLOv12n produced no detections across \(frames.count) frames"
    )

    // A full-body dancer clip should surface the COCO "person" class on at
    // least one frame — proof the baked label set is decoding correctly.
    #expect(
        sawPerson,
        "Expected a \"person\" detection; labels seen across frames: \(labelsSeen.sorted())"
    )

    let detection = try #require(sampleDetection, "No detection captured to inspect")

    // Box must be non-empty and normalized in [0, 1].
    #expect(detection.boundingBox.width > 0 && detection.boundingBox.height > 0)
    #expect(
        detection.boundingBox.minX >= -0.001 && detection.boundingBox.maxX <= 1.001,
        "Box X out of normalized range: \(detection.boundingBox)"
    )
    #expect(
        detection.boundingBox.minY >= -0.001 && detection.boundingBox.maxY <= 1.001,
        "Box Y out of normalized range: \(detection.boundingBox)"
    )

    // Confidence is a real probability here (path-A YOLO): (0, 1].
    #expect(detection.confidence > 0 && detection.confidence <= 1)

    // sourceModelID is stamped from the detector.
    #expect(detection.sourceModelID == "coreml.yolo12n")

    // Path-A YOLO is a pure box detector — no keypoints or skeleton.
    #expect(detection.keypoints == nil)
    #expect(detection.skeleton == nil)
}
