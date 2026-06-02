import CoreML
import Foundation
import Testing

@testable import Iris

/// Fixture test for `CoreMLDetector` + `YOLOEnd2EndDecoder` (**path B**)
/// against the converted YOLO26n model and a real clip.
///
/// The model fixture (`yolo26n.mlpackage`, an *end2end* one-to-one head with a
/// single `[1, 300, 6]` raw-tensor output and **no embedded labels** —
/// `METADATA keys: []`) lives under `Tests/.../Fixtures/` tracked via Git LFS.
/// It's compiled to an `.mlmodelc` at runtime via
/// `CoreMLModelLoading.compileAndLoad(at:)`; Iris never commits a compiled
/// model. The clip is the same `dancer-full-body.mp4` the path-A test uses; it
/// has a person on screen, so the decoder should emit a `"person"` detection
/// once the class index (0) is mapped through `COCOLabels.coco80`.
///
/// Mirrors `CoreMLDetectorFixtureTests` in shape: shared `decodeFrames`, an LFS
/// guard via `#require`, ~10 frames, loose floors for determinism. Adds a
/// **threshold-knob** assertion (low vs. high confidence floor) to prove the
/// `TunableDetector` rebuild path on the path-B detector.
@Test
func yoloEnd2EndDecoderDetectsPersonOnDancerClip() async throws {
    let modelURL = try #require(
        Bundle.module.url(forResource: "yolo26n", withExtension: "mlpackage"),
        """
        Missing fixture yolo26n.mlpackage — \
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
        decoder: YOLOEnd2EndDecoder(labels: COCOLabels.coco80, confidenceThreshold: 0.25),
        modelIdentifier: "coreml.yolo26n"
    )

    // M10·P1: the wrapping detector projects the decoder's class roster as
    // `capabilities.availableLabels` — the per-class tuning panel's "show all"
    // source. Proof the projection holds on a real, model-backed detector.
    let availableLabels = try #require(
        detector.capabilities.availableLabels,
        "YOLO detector must expose its COCO label set as availableLabels"
    )
    #expect(availableLabels == COCOLabels.coco80)
    #expect(availableLabels.contains("person"))

    let frames = try await decodeFrames(from: clipURL, maximumFrames: 10)
    #expect(frames.count == 10, "Expected to decode 10 frames, got \(frames.count)")

    var totalDetections = 0
    var sawPerson = false
    var personDetection: Detection?
    var sampleDetection: Detection?
    var labelsSeen: Set<String> = []

    for frame in frames {
        let detections = try await detector.detect(in: frame)
        totalDetections += detections.count
        for d in detections {
            labelsSeen.insert(d.label)
            if d.label == "person" {
                sawPerson = true
                personDetection = personDetection ?? d
            }
        }
        sampleDetection = sampleDetection ?? detections.first
    }

    #expect(
        totalDetections >= 1,
        "YOLO26n produced no detections across \(frames.count) frames"
    )

    // A full-body dancer clip should surface the COCO "person" class — proof
    // the external COCO-80 label mapping decodes correctly (the model carries
    // no embedded labels).
    #expect(
        sawPerson,
        "Expected a \"person\" detection; labels seen across frames: \(labelsSeen.sorted())"
    )

    let detection = try #require(
        personDetection ?? sampleDetection,
        "No detection captured to inspect"
    )

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

    // Confidence is a real class probability here (path-B YOLO): (0, 1].
    #expect(detection.confidence > 0 && detection.confidence <= 1)

    // sourceModelID is stamped from the detector.
    #expect(detection.sourceModelID == "coreml.yolo26n")

    // Path-B YOLO is a pure box detector — no keypoints or skeleton.
    #expect(detection.keypoints == nil)
    #expect(detection.skeleton == nil)

    // Box-placement sanity (the letterbox-inverse + Y-flip is the trap): the
    // dancer fills the frame center vertically, so the person box should be a
    // substantial, plausibly-centered region — not pinned to a corner or
    // spanning the whole frame. The clip is 1280×720 letterboxed into 640²,
    // so a correct inverse maps the person to roughly the middle horizontally
    // and a tall slice vertically.
    if let person = personDetection {
        let b = person.boundingBox
        // A real person box should be a meaningful fraction of the frame, not
        // a degenerate sliver nor the entire frame.
        #expect(
            b.height > 0.15 && b.height < 1.0,
            "Person box height implausible (letterbox-inverse/Y-flip suspect): \(b)"
        )
        #expect(
            b.width > 0.05 && b.width < 1.0,
            "Person box width implausible: \(b)"
        )
        // Horizontal center should sit within the middle band, not jammed to
        // an edge — the dancer is roughly centered in the 16:9 frame.
        let cx = b.midX
        #expect(
            cx > 0.15 && cx < 0.85,
            "Person box horizontal center off to an edge (inverse-map suspect): cx=\(cx), box=\(b)"
        )
        // Logged for eyeball verification per the build-time sanity check.
        print("YOLO26n person box (normalized, lower-left origin): \(b), conf=\(person.confidence)")
    }

    // --- Threshold-knob exercise: prove the TunableDetector rebuild path. ---
    // A high confidence floor must yield no more detections than a low floor
    // (the high floor is a strict subset), and a near-1.0 floor should drop
    // essentially everything. Run on the first frame for determinism.
    let firstFrame = try #require(frames.first)

    let lowFloor = try CoreMLDetector(
        model: model,
        decoder: YOLOEnd2EndDecoder(labels: COCOLabels.coco80, confidenceThreshold: 0.10),
        modelIdentifier: "coreml.yolo26n"
    )
    let lowCount = try await lowFloor.detect(in: firstFrame).count

    // Rebuild via the actual TunableDetector.apply path (lowering would be
    // detector-tier; here we *raise*, exercising the filter-tier verdict too)
    // — but to prove the decoder-rebuild path, construct a high-floor detector
    // directly and confirm it produces strictly fewer (or equal) detections.
    let highFloor = try CoreMLDetector(
        model: model,
        decoder: YOLOEnd2EndDecoder(labels: COCOLabels.coco80, confidenceThreshold: 0.95),
        modelIdentifier: "coreml.yolo26n"
    )
    let highCount = try await highFloor.detect(in: firstFrame).count

    #expect(
        highCount <= lowCount,
        "Raising the confidence floor produced MORE detections (\(highCount) > \(lowCount)) — threshold knob not honored"
    )
    #expect(
        lowCount >= highCount,
        "Threshold knob sanity: low floor (\(lowCount)) should admit at least as many as high floor (\(highCount))"
    )

    // Exercise the apply(_:) rebuild seam directly: lowering the floor is a
    // detector-tier change that rebuilds around a new decoder; the rebuilt
    // detector must carry the new threshold in its settings.
    let raiseChange = SettingChange.float(
        key: YOLOEnd2EndDecoder.confidenceThresholdKey,
        from: 0.25,
        to: 0.50
    )
    let raiseResult = detector.apply(raiseChange)
    #expect(raiseResult.tier == .filter, "Raising the confidence floor should be filter-tier")

    let lowerChange = SettingChange.float(
        key: YOLOEnd2EndDecoder.confidenceThresholdKey,
        from: 0.25,
        to: 0.05
    )
    let lowerResult = detector.apply(lowerChange)
    #expect(lowerResult.tier == .detector, "Lowering the confidence floor should be detector-tier")
    if case .detector(let rebuilt) = lowerResult {
        let rebuiltCoreML = try #require(
            rebuilt as? CoreMLDetector<YOLOEnd2EndDecoder>,
            "Rebuilt detector was not a CoreMLDetector<YOLOEnd2EndDecoder>"
        )
        #expect(
            abs(rebuiltCoreML.settings.confidenceThreshold - 0.05) < 1e-6,
            "Rebuilt detector did not carry the new threshold: \(rebuiltCoreML.settings.confidenceThreshold)"
        )
    } else {
        Issue.record("Lowering the floor did not return a .detector(rebuilt:) result")
    }
}
