import Foundation
import Testing

@testable import Iris

/// Fixture test for `VisionBodyPoseDetector` against a real clip
/// (`dancer-full-body.mp4`, 1280×720, single full-body dancer). Uses the
/// shared `decodeFrames` helper in `Tests/IrisTests/Support/FixtureDecoding.swift`.
@Test
func visionBodyPoseDetectorFiresOnDancerClip() async throws {
    let url = try #require(
        Bundle.module.url(forResource: "dancer-full-body", withExtension: "mp4"),
        """
        Missing fixture dancer-full-body.mp4 — \
        run `git lfs install && git lfs pull` after clone.
        """
    )

    let frames = try await decodeFrames(from: url, maximumFrames: 10)
    #expect(frames.count == 10, "Expected to decode 10 frames, got \(frames.count)")

    let detector = VisionBodyPoseDetector()

    // Count frames that yield at least one pose carrying a substantial joint
    // set, and capture a representative detection to assert the skeleton is
    // stamped. A full-body dancer should pose well; the floor is loose for
    // determinism across Vision-revision bumps.
    var framesWithPose = 0
    var sampleDetection: Detection?
    var perFrameJointCounts: [Int] = []
    for frame in frames {
        let detections = try await detector.detect(in: frame)
        let rich = detections.filter { ($0.keypoints?.count ?? 0) >= 8 }
        perFrameJointCounts.append(detections.map { $0.keypoints?.count ?? 0 }.max() ?? 0)
        if let first = rich.first {
            framesWithPose += 1
            sampleDetection = sampleDetection ?? first
        }
    }

    #expect(
        framesWithPose >= 5,
        """
        Body pose fired on only \(framesWithPose)/\(frames.count) frames with ≥8 joints. \
        Per-frame max joint counts: \(perFrameJointCounts)
        """
    )

    // The detection must carry the canonical body-pose skeleton so the
    // overlay can draw the limbs.
    let detection = try #require(sampleDetection, "No pose detection captured")
    #expect(detection.skeleton == .humanBodyPose)
    #expect(detection.label == "person")

    // Capability-honest readout: the joint count, the meaningful number for
    // a pose (per-joint confidence makes a single probability meaningless).
    // Its text must reflect the keypoint count actually located.
    let readout = try #require(detection.readout, "Pose carried no readout")
    #expect(readout.label == "joints")
    let jointCount = detection.keypoints?.count ?? 0
    #expect(readout.text == "\(jointCount) joints")
}
