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
}

@Suite("VisionBodyPoseSettings")
struct VisionBodyPoseSettingsTests {

    @Test
    func schemaContainsDetectsHandsToggle() {
        let schema = VisionBodyPoseSettings.schema
        #expect(schema.knobs.count == 1)
        let knob = try? #require(schema.knobs.first)
        #expect(knob?.key == VisionBodyPoseSettings.detectsHandsKey)
        if case .toggle = knob?.kind {
            // expected
        } else {
            Issue.record("detectsHands knob should be a toggle")
        }
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
