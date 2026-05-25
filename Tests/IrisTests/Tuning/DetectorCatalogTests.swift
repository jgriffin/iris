import Testing

@testable import Iris

// MARK: - Test goal
//
// Per M5·P4: the general "select which detector is active + tune it" layer
// lives in Iris as `DetectorCatalog` / `DetectorCatalogEntry` /
// `ActiveDetectorSession`. These tests pin the built-in Vision catalog's
// shape and verify that an entry's factory builds a session whose
// type-erased `router.currentDetector` is the expected concrete detector.
//
// The `settingsView: AnyView` is intentionally not introspectable — the
// tests only assert a session *builds* and routes the right detector, not
// what its SwiftUI controls look like (that's covered by
// `CapabilityTuningProjection` derivation tests).

@MainActor
@Suite struct DetectorCatalogTests {

    @Test func builtInVisionHasTwoExpectedEntries() {
        let catalog = DetectorCatalog.builtInVision
        let ids = catalog.entries.map(\.id)

        #expect(catalog.entries.count == 2)
        #expect(ids == ["vision.rectangles", "vision.bodyPose"])
        #expect(catalog.entries.allSatisfy { !$0.displayName.isEmpty })
    }

    @Test func rectanglesEntryBuildsSessionRoutingRectangleDetector() throws {
        let entry = DetectorCatalog.builtInVision.entries.first {
            $0.id == "vision.rectangles"
        }
        let session = try #require(entry).makeSession(ResultStore())

        let detector = try #require(session.router.currentDetector)
        #expect(detector.modelIdentifier == "vision.rectangles")
    }

    @Test func bodyPoseEntryBuildsSessionRoutingBodyPoseDetector() throws {
        let entry = DetectorCatalog.builtInVision.entries.first {
            $0.id == "vision.bodyPose"
        }
        let session = try #require(entry).makeSession(ResultStore())

        let detector = try #require(session.router.currentDetector)
        #expect(detector.modelIdentifier == "vision.bodyPose")
    }
}
