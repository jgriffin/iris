import CoreML
import Foundation
import Testing

@testable import Iris

/// Tests for the M6·P3 model-loading half: ``CoreMLDetector/prewarm()`` and the
/// runtime file-load path the demo's file-picker drives
/// (`compileAndLoad(at:)` → build detector → run it).
///
/// The picker UI itself isn't unit-testable, but everything *behind* it is —
/// these exercise the exact load + warm-up code a file-picked Path-A model
/// runs, against the on-disk `yolo12n.mlpackage` fixture (LFS-tracked, same one
/// `CoreMLDetectorFixtureTests` uses). Standard `#require` LFS guards.

/// `prewarm()` must run cleanly and must not break the detector: after warming,
/// `detect(in:)` on the dancer clip still surfaces a `"person"`.
@Test
func prewarmDoesNotBreakCoreMLDetector() async throws {
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

    // The warm-up: must complete without throwing/crashing (it's `async` and
    // non-throwing by contract — a failure inside is swallowed + logged).
    await detector.prewarm()

    // Warming must not have disturbed the model: a real detect still works.
    let frames = try await decodeFrames(from: clipURL, maximumFrames: 10)
    #expect(frames.count == 10, "Expected 10 frames, got \(frames.count)")

    var sawPerson = false
    var labelsSeen: Set<String> = []
    for frame in frames {
        for d in try await detector.detect(in: frame) {
            labelsSeen.insert(d.label)
            if d.label == "person" { sawPerson = true }
        }
    }

    #expect(
        sawPerson,
        "After prewarm, expected a \"person\" detection; labels seen: \(labelsSeen.sorted())"
    )
}

/// The runtime file-load path the file-picker drives end to end:
/// `compileAndLoad(at:)` on a `.mlpackage` URL → `CoreMLDetector` with a
/// `VisionObjectDecoder` (Path A, self-describing labels, zero config) →
/// detects `"person"` on the dancer clip. This is exactly what the demo runs
/// after a pick, minus the picker UI.
@Test
func filePickedLoadPathDetectsPerson() async throws {
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

    // Mirror the file-picker handler: compile the picked package at runtime,
    // build a Path-A detector around it, warm it, then run it.
    let model = try await CoreMLModelLoading.compileAndLoad(at: modelURL)
    let detector = try CoreMLDetector(
        model: model,
        decoder: VisionObjectDecoder(),
        // The picker stamps the file basename as the model identifier.
        modelIdentifier: modelURL.deletingPathExtension().lastPathComponent
    )
    await detector.prewarm()

    // A freshly-loaded, available detector reports `.available`.
    #expect(detector.availability == .available)
    #expect(detector.modelIdentifier == "yolo12n")

    let frames = try await decodeFrames(from: clipURL, maximumFrames: 10)
    var sawPerson = false
    var labelsSeen: Set<String> = []
    for frame in frames {
        for d in try await detector.detect(in: frame) {
            labelsSeen.insert(d.label)
            if d.label == "person" { sawPerson = true }
        }
    }

    #expect(
        sawPerson,
        "File-picked load path: expected a \"person\" detection; labels seen: \(labelsSeen.sorted())"
    )
}

/// Availability semantics the picker UI reads: a not-yet-loaded placeholder
/// reports `.modelNotReady`; a loaded `CoreMLDetector` reports `.available`.
@Test
func availabilityReflectsLoadState() async throws {
    // A placeholder standing in for the unloaded file-pick slot.
    let placeholder = NotReadyDetector(modelIdentifier: "coreml.custom")
    #expect(placeholder.availability == .modelNotReady)

    let modelURL = try #require(
        Bundle.module.url(forResource: "yolo12n", withExtension: "mlpackage"),
        """
        Missing fixture yolo12n.mlpackage — \
        run `git lfs install && git lfs pull` after clone.
        """
    )
    let model = try await CoreMLModelLoading.compileAndLoad(at: modelURL)
    let loaded = try CoreMLDetector(
        model: model,
        decoder: VisionObjectDecoder(),
        modelIdentifier: "coreml.custom"
    )
    #expect(loaded.availability == .available)
}

/// Stand-in for the demo's `.modelNotReady` placeholder entry (the file-pick
/// slot before the user supplies a model). Kept in the test target so the
/// availability assertion doesn't depend on demo-app code, which the package
/// tests can't import.
private struct NotReadyDetector: Detector {
    let availability: DetectorAvailability = .modelNotReady
    let modelIdentifier: String
    func prewarm() async {}
    func detect(in _: Frame) async throws -> [Detection] { [] }
}
