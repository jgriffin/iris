import Testing

@testable import Iris

// MARK: - Test goal
//
// `VisionRectanglesDetector.apply(_:)` Phase 2 wiring: on `.detector`
// arms, return a freshly-constructed `VisionRectanglesDetector` whose
// `settings` reflect the post-change value. Pins the Phase 1
// `TODO M4 Phase 2:` placeholder replacements as locked behavior.

// MARK: - minimumConfidence (lower-bound → .detector on lower)

@Test
func minimumConfidenceLowerReturnsRebuiltDetectorWithNewSettings() throws {
    let detector = VisionRectanglesDetector(
        settings: VisionRectanglesSettings(minimumConfidence: 0.6)
    )
    let change = SettingChange.float(key: "minimumConfidence", from: 0.6, to: 0.2)

    let result = detector.apply(change)
    guard case .detector(let rebuilt) = result else {
        Issue.record("Expected .detector verdict, got \(result)")
        return
    }
    let cast = try #require(rebuilt as? VisionRectanglesDetector)
    #expect(cast.settings.minimumConfidence == 0.2)
    // Other knobs preserved from the original.
    #expect(cast.settings.minimumAspectRatio == detector.settings.minimumAspectRatio)
    #expect(cast.settings.label == detector.settings.label)
}

// MARK: - maximumAspectRatio (upper-bound → .detector on raise)

@Test
func maximumAspectRatioRaiseReturnsRebuiltDetectorWithNewSettings() throws {
    let detector = VisionRectanglesDetector(
        settings: VisionRectanglesSettings(maximumAspectRatio: 0.6)
    )
    let change = SettingChange.float(key: "maximumAspectRatio", from: 0.6, to: 0.9)

    let result = detector.apply(change)
    guard case .detector(let rebuilt) = result else {
        Issue.record("Expected .detector verdict, got \(result)")
        return
    }
    let cast = try #require(rebuilt as? VisionRectanglesDetector)
    #expect(cast.settings.maximumAspectRatio == 0.9)
}

// MARK: - quadratureToleranceDegrees (upper-bound → .detector on raise)

@Test
func quadratureToleranceRaiseReturnsRebuiltDetectorWithNewSettings() throws {
    let detector = VisionRectanglesDetector(
        settings: VisionRectanglesSettings(quadratureToleranceDegrees: 20.0)
    )
    let change = SettingChange.float(
        key: "quadratureToleranceDegrees",
        from: 20.0,
        to: 40.0
    )

    let result = detector.apply(change)
    guard case .detector(let rebuilt) = result else {
        Issue.record("Expected .detector verdict, got \(result)")
        return
    }
    let cast = try #require(rebuilt as? VisionRectanglesDetector)
    #expect(cast.settings.quadratureToleranceDegrees == 40.0)
}

// MARK: - minimumSize (lower-bound → .detector on lower)

@Test
func minimumSizeLowerReturnsRebuiltDetectorWithNewSettings() throws {
    let detector = VisionRectanglesDetector(
        settings: VisionRectanglesSettings(minimumSize: 0.5)
    )
    let change = SettingChange.float(key: "minimumSize", from: 0.5, to: 0.1)

    let result = detector.apply(change)
    guard case .detector(let rebuilt) = result else {
        Issue.record("Expected .detector verdict, got \(result)")
        return
    }
    let cast = try #require(rebuilt as? VisionRectanglesDetector)
    #expect(cast.settings.minimumSize == 0.1)
}

// MARK: - maximumObservations (larger cap → .detector)

@Test
func maximumObservationsRaiseReturnsRebuiltDetectorWithNewSettings() throws {
    let detector = VisionRectanglesDetector(
        settings: VisionRectanglesSettings(maximumObservations: 5)
    )
    let change = SettingChange.int(key: "maximumObservations", from: 5, to: 20)

    let result = detector.apply(change)
    guard case .detector(let rebuilt) = result else {
        Issue.record("Expected .detector verdict, got \(result)")
        return
    }
    let cast = try #require(rebuilt as? VisionRectanglesDetector)
    #expect(cast.settings.maximumObservations == 20)
}

@Test
func maximumObservationsToUnlimitedReturnsRebuiltDetectorWithNewSettings() throws {
    // Finite → 0 (unlimited) is detector-tier — surfaces previously
    // truncated observations.
    let detector = VisionRectanglesDetector(
        settings: VisionRectanglesSettings(maximumObservations: 5)
    )
    let change = SettingChange.int(key: "maximumObservations", from: 5, to: 0)

    let result = detector.apply(change)
    guard case .detector(let rebuilt) = result else {
        Issue.record("Expected .detector verdict, got \(result)")
        return
    }
    let cast = try #require(rebuilt as? VisionRectanglesDetector)
    #expect(cast.settings.maximumObservations == 0)
}

// MARK: - Filter arms do not produce a rebuilt detector

@Test
func minimumConfidenceRaiseDoesNotProduceRebuiltDetector() {
    let detector = VisionRectanglesDetector(
        settings: VisionRectanglesSettings(minimumConfidence: 0.2)
    )
    let change = SettingChange.float(key: "minimumConfidence", from: 0.2, to: 0.6)

    let result = detector.apply(change)
    if case .detector = result {
        Issue.record("Filter-tier transition produced a .detector verdict: \(result)")
    }
    #expect(result.tier == .filter)
}
