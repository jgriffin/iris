import CoreGraphics
import CoreMedia
import Foundation
import Testing

@testable import Iris

// MARK: - Helpers

/// A fresh temp-dir `FlagStore` plus a `MockFlaggingSource`, wired into a
/// `FlaggingModel`. `@MainActor` because every collaborator is.
@MainActor
private func makeModel(
    currentPTS: CMTime? = .zero,
    detections: [Detection] = [],
    asset: AssetFingerprint = .preview()
) -> (model: FlaggingModel, source: MockFlaggingSource, store: FlagStore, dir: URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("iris-flagmodel-\(UUID().uuidString)", isDirectory: true)
    let store = FlagStore(baseDir: dir)
    let source = MockFlaggingSource(currentPTS: currentPTS, detections: detections)
    let model = FlaggingModel(store: store, source: source)
    model.setAssetForTesting(asset)
    return (model, source, store, dir)
}

private func sampleDetection(modelID: String = "yolo26n") -> Detection {
    Detection(
        boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
        label: "person",
        confidence: 0.9,
        sourceModelID: modelID
    )
}

/// Resolve a bundled fixture clip (LFS-tracked).
private func fixtureURL(_ name: String, ext: String = "mp4") throws -> URL {
    try #require(
        Bundle.module.url(forResource: name, withExtension: ext),
        "Missing fixture \(name).\(ext) — run `git lfs install && git lfs pull`."
    )
}

// MARK: - Tests

@Suite("FlaggingModel")
@MainActor
struct FlaggingModelTests {

    @Test("toggleCurrent with no flag adds one carrying detections + default reason")
    func toggleAddsFlag() throws {
        let pts = CMTime(value: 300, timescale: 600)  // 0.5 s
        let dets = [sampleDetection()]
        let (model, source, store, dir) = makeModel(currentPTS: pts, detections: dets)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Keep the unowned-referenced source alive for the model's lifetime.
        defer { _ = source }

        #expect(model.currentFlags.isEmpty)

        model.toggleCurrent()

        let flags = model.currentFlags
        try #require(flags.count == 1)
        let flag = flags[0]
        #expect(CMTimeCompare(flag.ref.pts, pts) == 0)
        #expect(flag.detections == dets)
        #expect(flag.reason == .wrong)
        #expect(flag.modelID == "yolo26n")
        #expect(flag.confidenceThreshold == nil)
        // Persisted, not just cached.
        #expect(store.flags(for: .preview()).count == 1)
    }

    @Test("toggleCurrent twice at the same PTS removes the flag")
    func toggleRemovesFlag() {
        let pts = CMTime(value: 300, timescale: 600)
        let (model, source, _, dir) = makeModel(currentPTS: pts, detections: [sampleDetection()])
        defer { try? FileManager.default.removeItem(at: dir) }
        defer { _ = source }

        model.toggleCurrent()
        #expect(model.currentFlags.count == 1)

        model.toggleCurrent()
        #expect(model.currentFlags.isEmpty)
    }

    @Test("isCurrentFlagged is true within the half-frame tolerance, false outside")
    func toleranceWindow() {
        // Flag at exactly 1.0 s.
        let flagPTS = CMTime(value: 600, timescale: 600)
        let (model, source, _, dir) = makeModel(currentPTS: flagPTS)
        defer { try? FileManager.default.removeItem(at: dir) }

        model.toggleCurrent()
        #expect(model.isCurrentFlagged())

        // Within ½ frame at 30fps = 1/60 s ≈ 16.67 ms. Nudge by 10 ms → still flagged.
        source.currentPTS = flagPTS + CMTime(value: 6, timescale: 600)  // +10 ms
        #expect(model.isCurrentFlagged())

        // Nudge by 50 ms → outside the window → not flagged.
        source.currentPTS = flagPTS + CMTime(value: 30, timescale: 600)  // +50 ms
        #expect(!model.isCurrentFlagged())
    }

    @Test("jump seeks to the flag's exact stored PTS")
    func jumpSeeksExact() throws {
        let flagPTS = CMTime(value: 1001, timescale: 30000)  // non-trivial rational
        let (model, source, _, dir) = makeModel(currentPTS: flagPTS)
        defer { try? FileManager.default.removeItem(at: dir) }

        model.toggleCurrent()
        let flag = try #require(model.currentFlags.first)

        // Move the playhead away, then jump back.
        source.currentPTS = CMTime(value: 5, timescale: 1)
        model.jump(to: flag)

        let target = try #require(source.lastSeekTarget)
        #expect(CMTimeCompare(target, flagPTS) == 0)
    }

    @Test("setAsset on a fixture populates asset; currentFlags reflects the store")
    func setAssetPopulatesFromStore() async throws {
        let url = try fixtureURL("dancer-full-body")
        let fingerprint = try await AssetFingerprint.compute(url: url)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-flagmodel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FlagStore(baseDir: dir)

        // Pre-seed a flag for this exact asset.
        let seeded = FrameFlag(
            ref: FrameRef(asset: fingerprint, pts: CMTime(value: 300, timescale: 600)),
            detections: [sampleDetection()],
            reason: .nearMiss
        )
        store.add(seeded)

        let source = MockFlaggingSource(currentPTS: .zero)
        let model = FlaggingModel(store: store, source: source)
        #expect(model.asset == nil)
        #expect(model.currentFlags.isEmpty)

        await model.setAsset(url: url)

        #expect(model.asset == fingerprint)
        #expect(model.currentFlags.count == 1)
        #expect(model.currentFlags.first?.reason == .nearMiss)
    }
}
