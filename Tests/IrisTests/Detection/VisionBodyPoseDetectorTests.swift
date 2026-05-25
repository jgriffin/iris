import CoreGraphics
import Testing

@testable import Iris

@Suite("VisionBodyPoseDetector")
struct VisionBodyPoseDetectorTests {

    // MARK: - Capabilities

    @Test
    func capabilitiesDeclareKeypointsAndPerElementConfidence() {
        let detector = VisionBodyPoseDetector()
        let caps = detector.capabilities
        #expect(caps.geometryKinds == [.keypoints])
        #expect(caps.confidence == .perElement)
    }

    @Test
    func capabilitiesReuseSettingsSchema() {
        let detector = VisionBodyPoseDetector()
        #expect(detector.capabilities.tunableKnobs == VisionBodyPoseSettings.schema)
    }

    @Test
    func modelIdentifierAndAvailability() {
        let detector = VisionBodyPoseDetector()
        #expect(detector.modelIdentifier == "vision.bodyPose")
        #expect(detector.availability == .available)
    }

    @Test
    func convenienceInitForwardsDetectsHands() {
        #expect(VisionBodyPoseDetector(detectsHands: true).settings.detectsHands)
        #expect(!VisionBodyPoseDetector().settings.detectsHands)
    }

    // MARK: - apply()

    @Test
    func detectsHandsChangeIsDetectorTier() {
        let detector = VisionBodyPoseDetector(detectsHands: false)
        let change = SettingChange.toggle(
            key: VisionBodyPoseSettings.detectsHandsKey,
            from: false,
            to: true
        )
        let result = detector.apply(change)
        #expect(result.tier == .detector)
        if case .detector(let rebuilt) = result {
            let rebuiltPose = try? #require(rebuilt as? VisionBodyPoseDetector)
            #expect(rebuiltPose?.settings.detectsHands == true)
        } else {
            Issue.record("Expected .detector result")
        }
    }

    @Test
    func noOpChangeIsViewTier() {
        let detector = VisionBodyPoseDetector(detectsHands: true)
        let change = SettingChange.toggle(
            key: VisionBodyPoseSettings.detectsHandsKey,
            from: true,
            to: true
        )
        #expect(detector.apply(change).tier == .view)
    }

    @Test
    func minimumJointConfidenceChangeIsFilterTier() {
        let detector = VisionBodyPoseDetector()
        let change = SettingChange.float(
            key: VisionBodyPoseSettings.minimumJointConfidenceKey,
            from: 0.3,
            to: 0.5
        )
        // Filter-tier in both directions — the floor re-runs over the
        // cached detections without re-inference (mirrors rectangles'
        // quadrature knob). Verify both raise and lower stay filter-tier.
        #expect(detector.apply(change).tier == .filter)
        let lowered = SettingChange.float(
            key: VisionBodyPoseSettings.minimumJointConfidenceKey,
            from: 0.3,
            to: 0.1
        )
        #expect(detector.apply(lowered).tier == .filter)
    }

    // MARK: - transform(for:) joint-confidence filter

    /// Synthetic pose with mixed-confidence joints — some below the 0.3
    /// floor (including a phantom at exactly (0,0) with ~0 confidence),
    /// some well above. The default-threshold transform should drop the
    /// low ones, recompute the envelope to exclude the (0,0) phantom, and
    /// rewrite the joint-count readout.
    @Test
    func transformDropsLowConfidenceJointsAndRecomputesEnvelope() {
        let keypoints: [Detection.Keypoint] = [
            // Phantom undetected joint Vision parks at the origin.
            Detection.Keypoint(name: "leftEar", position: CGPoint(x: 0, y: 0), confidence: 0.0),
            // Below the 0.3 default floor.
            Detection.Keypoint(
                name: "rightEar", position: CGPoint(x: 0.4, y: 0.6), confidence: 0.2),
            // Above the floor — kept.
            Detection.Keypoint(name: "nose", position: CGPoint(x: 0.5, y: 0.7), confidence: 0.9),
            Detection.Keypoint(
                name: "neck", position: CGPoint(x: 0.5, y: 0.6), confidence: 0.85),
            Detection.Keypoint(
                name: "leftShoulder", position: CGPoint(x: 0.45, y: 0.55), confidence: 0.8),
        ]
        let detection = Detection(
            boundingBox: CGRect(x: 0, y: 0, width: 0.5, height: 0.7),
            label: "person",
            confidence: 0.55,
            keypoints: keypoints,
            skeleton: .humanBodyPose,
            readout: Readout(label: "joints", text: "5 joints"),
            sourceModelID: "vision.bodyPose"
        )

        let transform = VisionBodyPoseDetector.transform(
            for: VisionBodyPoseSettings()  // default 0.3 floor
        )
        let out = transform([detection])

        let result = try? #require(out.first)
        let kept = try? #require(result?.keypoints)
        // Only the three ≥ 0.3 joints survive.
        #expect(kept?.count == 3)
        #expect(kept?.allSatisfy { $0.confidence >= 0.3 } == true)
        // The (0,0) phantom is gone — no surviving joint sits at the origin.
        #expect(kept?.contains { $0.position == CGPoint(x: 0, y: 0) } == false)

        // Envelope recomputed from the three remaining joints (x ∈ [0.45,
        // 0.5], y ∈ [0.55, 0.7]); the (0,0) joint no longer pins the box.
        #expect(result?.boundingBox.minX == 0.45)
        #expect(result?.boundingBox.minY == 0.55)
        #expect(result?.boundingBox.maxX == 0.5)
        #expect(result?.boundingBox.maxY == 0.7)

        // Readout reflects the filtered count.
        #expect(result?.readout?.text == "3 joints")

        // Mean confidence recomputed from the survivors only.
        let expectedMean = (Float(0.9) + 0.85 + 0.8) / 3
        #expect(abs((result?.confidence ?? 0) - expectedMean) < 1e-5)

        // Self-describing fields preserved.
        #expect(result?.label == "person")
        #expect(result?.skeleton == .humanBodyPose)
        #expect(result?.sourceModelID == "vision.bodyPose")
    }

    @Test
    func transformDropsDetectionWhenAllJointsBelowFloor() {
        let keypoints: [Detection.Keypoint] = [
            Detection.Keypoint(name: "nose", position: CGPoint(x: 0.1, y: 0.1), confidence: 0.1),
            Detection.Keypoint(name: "neck", position: CGPoint(x: 0, y: 0), confidence: 0.0),
        ]
        let detection = Detection(
            boundingBox: CGRect(x: 0, y: 0, width: 0.1, height: 0.1),
            label: "person",
            confidence: 0.05,
            keypoints: keypoints,
            skeleton: .humanBodyPose,
            readout: Readout(label: "joints", text: "2 joints"),
            sourceModelID: "vision.bodyPose"
        )
        let transform = VisionBodyPoseDetector.transform(for: VisionBodyPoseSettings())
        #expect(transform([detection]).isEmpty)
    }

    @Test
    func transformPassesThroughDetectionWithoutKeypoints() {
        // A non-pose detection routed through the same transform — the
        // filter can't judge joints it doesn't carry, so it abstains.
        let detection = Detection(
            boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
            label: "rect",
            confidence: 1.0,
            keypoints: nil,
            sourceModelID: "vision.rectangles"
        )
        let transform = VisionBodyPoseDetector.transform(for: VisionBodyPoseSettings())
        let out = transform([detection])
        #expect(out.count == 1)
        #expect(out.first == detection)
    }
}

@Suite("VisionBodyPoseSettings")
struct VisionBodyPoseSettingsTests {

    @Test
    func schemaContainsDetectsHandsToggle() {
        let schema = VisionBodyPoseSettings.schema
        #expect(schema.knobs.count == 2)
        let knob = try? #require(
            schema.knobs.first { $0.key == VisionBodyPoseSettings.detectsHandsKey }
        )
        #expect(knob?.key == VisionBodyPoseSettings.detectsHandsKey)
        if case .toggle = knob?.kind {
            // expected
        } else {
            Issue.record("detectsHands knob should be a toggle")
        }
    }

    @Test
    func schemaContainsMinimumJointConfidenceSlider() {
        let schema = VisionBodyPoseSettings.schema
        let knob = try? #require(
            schema.knobs.first { $0.key == VisionBodyPoseSettings.minimumJointConfidenceKey }
        )
        #expect(knob?.tier == .filter)
        if case .float(let range, let step, let dflt) = knob?.kind {
            #expect(range == 0.0...1.0)
            #expect(step == 0.05)
            #expect(dflt == 0.3)
        } else {
            Issue.record("minimumJointConfidence knob should be a float slider")
        }
    }

    @Test
    func defaultMinimumJointConfidenceIsPointThree() {
        #expect(VisionBodyPoseSettings().minimumJointConfidence == 0.3)
    }

    @Test
    func valueAccessorsRoundTrip() {
        var settings = VisionBodyPoseSettings(detectsHands: false)
        #expect(settings.value(forKey: VisionBodyPoseSettings.detectsHandsKey) == .toggle(false))

        settings.setValue(.toggle(true), forKey: VisionBodyPoseSettings.detectsHandsKey)
        #expect(settings.detectsHands)
        #expect(settings.value(forKey: VisionBodyPoseSettings.detectsHandsKey) == .toggle(true))
    }

    @Test
    func minimumJointConfidenceAccessorsRoundTrip() {
        var settings = VisionBodyPoseSettings()
        #expect(
            settings.value(forKey: VisionBodyPoseSettings.minimumJointConfidenceKey)
                == .float(0.3)
        )

        settings.setValue(.float(0.6), forKey: VisionBodyPoseSettings.minimumJointConfidenceKey)
        #expect(settings.minimumJointConfidence == 0.6)
        #expect(
            settings.value(forKey: VisionBodyPoseSettings.minimumJointConfidenceKey)
                == .float(0.6)
        )
    }

    @Test
    func minimumJointConfidenceKeyPathBridge() {
        #expect(
            VisionBodyPoseSettings.key(for: \.minimumJointConfidence)
                == VisionBodyPoseSettings.minimumJointConfidenceKey
        )
    }

    @Test
    func mismatchedPayloadIsDropped() {
        var settings = VisionBodyPoseSettings(detectsHands: false)
        settings.setValue(.float(1.0), forKey: VisionBodyPoseSettings.detectsHandsKey)
        #expect(!settings.detectsHands, "A float payload should not write the toggle")
    }

    @Test
    func keyPathBridgeMapsDetectsHands() {
        #expect(
            VisionBodyPoseSettings.key(for: \.detectsHands)
                == VisionBodyPoseSettings.detectsHandsKey
        )
    }
}
