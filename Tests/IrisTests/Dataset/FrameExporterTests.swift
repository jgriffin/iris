import CoreGraphics
import CoreMedia
import Foundation
import Testing

@testable import Iris

// MARK: - Helpers

/// Resolve a bundled fixture clip, requiring it to exist (LFS-tracked).
private func exporterFixtureURL(_ name: String, ext: String = "mp4") throws -> URL {
    try #require(
        Bundle.module.url(forResource: name, withExtension: ext),
        "Missing fixture \(name).\(ext) — run `git lfs install && git lfs pull` after clone."
    )
}

/// A fresh temp dir for a store/sink `baseDir`.
private func tempBaseDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("iris-exporter-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Build a `FrameFlag` for the fixture at a target time *without* opening a
/// `PlaybackSource` — only the (cheap, bounded-read) fingerprint is computed.
///
/// The PTS is a plain in-range `CMTime`; `PlaybackSource.seek` resolves it to
/// the nearest real sample via `.zero` tolerance at extraction time, so the
/// frame still decodes. Avoiding a second concurrent AVF asset here keeps the
/// suite from blowing `ensureReadyToPlay`'s 2s deadline under parallel load.
private func fixtureFlag(
    for url: URL,
    atSeconds seconds: Double,
    reason: FlagReason = .wrong
) async throws -> FrameFlag {
    let fingerprint = try await AssetFingerprint.compute(url: url)
    let detection = Detection(
        boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
        label: "person",
        confidence: 0.5,
        sourceModelID: "test"
    )
    return FrameFlag(
        ref: FrameRef(asset: fingerprint, pts: CMTime(seconds: seconds, preferredTimescale: 600)),
        detections: [detection],
        modelID: "test",
        confidenceThreshold: 0.25,
        reason: reason,
        note: "exporter fixture"
    )
}

/// A flag for an asset that does NOT correspond to any real file — used to seed
/// an "unreachable" entry in the store.
private func syntheticFlag(filename: String, headHash: String) -> FrameFlag {
    let fp = AssetFingerprint(
        filename: filename,
        byteSize: 4242,
        durationSeconds: 7.5,
        headHash: headHash
    )
    return FrameFlag(
        ref: FrameRef(asset: fp, pts: CMTime(value: 1500, timescale: 1000)),
        detections: [],
        reason: .nearMiss,
        note: "unreachable seed"
    )
}

// MARK: - allFlaggedAssets

@Suite("FlagStore.allFlaggedAssets")
struct AllFlaggedAssetsTests {

    @Test("enumerates flag files written for different fingerprints")
    @MainActor
    func enumeratesMultipleFingerprints() throws {
        let baseDir = try tempBaseDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let store = FlagStore(baseDir: baseDir)
        let a = syntheticFlag(filename: "a.mp4", headHash: "aaaa")
        let b = syntheticFlag(filename: "b.mp4", headHash: "bbbb")
        let c = syntheticFlag(filename: "c.mp4", headHash: "cccc")
        store.add(a)
        store.add(b)
        store.add(c)

        // Fresh store on the same dir ⇒ forces a disk scan, not just cache.
        let reloaded = FlagStore(baseDir: baseDir)
        let all = reloaded.allFlaggedAssets()

        #expect(all.count == 3)
        let ids = Set(all.map { $0.asset.id })
        #expect(ids == Set([a.ref.asset.id, b.ref.asset.id, c.ref.asset.id]))
        for entry in all {
            #expect(entry.flags.count == 1)
            #expect(entry.flags.first?.ref.asset.id == entry.asset.id)
        }
    }

    @Test("empty when nothing flagged")
    @MainActor
    func emptyWhenNoFlags() throws {
        let baseDir = try tempBaseDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let store = FlagStore(baseDir: baseDir)
        #expect(store.allFlaggedAssets().isEmpty)
    }
}

// MARK: - Sweep

// `.serialized`: each test drives a real AVF `PlaybackSource` via the sweep's
// `extract`. Running them in parallel — on top of the other fixture-heavy AVF
// suites — can blow `PlaybackSource.ensureReadyToPlay`'s 2s asset-load deadline
// under load. Serializing this suite caps the concurrent asset count and keeps
// the run deterministic without touching production.
@Suite("FrameExporter sweep", .serialized)
struct FrameExporterSweepTests {

    @Test("sweep extracts pending frames; a second run skips them all (resumable)")
    @MainActor
    func sweepExtractsThenResumes() async throws {
        let url = try exporterFixtureURL("dancer-full-body")
        let flag = try await fixtureFlag(for: url, atSeconds: 0.5)

        let baseDir = try tempBaseDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let store = FlagStore(baseDir: baseDir)
        store.add(flag)
        let sink = FolderDatasetSink(baseDir: baseDir)
        let exporter = FrameExporter(store: store)

        let first = try await exporter.sweep(sources: [url], into: sink)
        #expect(first.written == 1)
        #expect(first.skipped == 0)
        #expect(first.unreachable.isEmpty)
        #expect(first.assets.count == 1)
        #expect(first.assets.first?.fingerprintID == flag.ref.asset.id)
        #expect(first.assets.first?.written == 1)

        // Second sweep over the same sources: everything is on disk now.
        let second = try await exporter.sweep(sources: [url], into: sink)
        #expect(second.written == 0)
        #expect(second.skipped == 1)
        #expect(second.unreachable.isEmpty)

        // Exactly one PNG on disk after both runs.
        let entries = try FileManager.default.contentsOfDirectory(atPath: sink.framesDir.path)
        #expect(entries.count == 1)
    }

    @Test("unreachable assets are reported with filename + pending count; reachable ones still extract")
    @MainActor
    func reportsUnreachable() async throws {
        let url = try exporterFixtureURL("dancer-full-body")
        let reachableFlag = try await fixtureFlag(for: url, atSeconds: 0.5)

        let baseDir = try tempBaseDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let store = FlagStore(baseDir: baseDir)
        store.add(reachableFlag)

        // A flagged asset whose source URL is NOT in the candidate list.
        let unreachableFlag = syntheticFlag(filename: "ghost-clip.mp4", headHash: "ff00ff00")
        store.add(unreachableFlag)

        let sink = FolderDatasetSink(baseDir: baseDir)
        let exporter = FrameExporter(store: store)

        // Only the reachable URL is supplied.
        let summary = try await exporter.sweep(sources: [url], into: sink)

        // Reachable asset extracted.
        #expect(summary.written == 1)
        #expect(summary.assets.contains { $0.fingerprintID == reachableFlag.ref.asset.id })

        // Unreachable asset reported.
        #expect(summary.unreachable.count == 1)
        let entry = try #require(summary.unreachable.first)
        #expect(entry.fingerprintID == unreachableFlag.ref.asset.id)
        #expect(entry.displayFilename == "ghost-clip.mp4")
        #expect(entry.pendingCount == 1)
    }

    @Test("pre-cancelled sweep throws CancellationError and writes nothing")
    @MainActor
    func cancellationWritesNothing() async throws {
        let url = try exporterFixtureURL("dancer-full-body")
        let flag = try await fixtureFlag(for: url, atSeconds: 0.5)

        let baseDir = try tempBaseDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let store = FlagStore(baseDir: baseDir)
        store.add(flag)
        let sink = FolderDatasetSink(baseDir: baseDir)
        let exporter = FrameExporter(store: store)

        // A task cancelled before it runs: the first checkCancellation throws.
        let task = Task { @MainActor in
            try await exporter.sweep(sources: [url], into: sink)
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }

        // Nothing written.
        let exists = FileManager.default.fileExists(atPath: sink.framesDir.path)
        if exists {
            let entries = try FileManager.default.contentsOfDirectory(atPath: sink.framesDir.path)
            #expect(entries.isEmpty, "a cancelled sweep must not write frames")
        }
    }

    @Test("already-present frames are untouched by a cancelled sweep")
    @MainActor
    func cancellationLeavesExistingFrames() async throws {
        let url = try exporterFixtureURL("dancer-full-body")
        let flag = try await fixtureFlag(for: url, atSeconds: 0.5)

        let baseDir = try tempBaseDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let store = FlagStore(baseDir: baseDir)
        store.add(flag)
        let sink = FolderDatasetSink(baseDir: baseDir)
        let exporter = FrameExporter(store: store)

        // Populate one frame.
        try await exporter.sweep(sources: [url], into: sink)
        #expect(sink.contains(flag.ref))

        // A pre-cancelled re-sweep must throw and leave the existing PNG alone.
        let task = Task { @MainActor in
            try await exporter.sweep(sources: [url], into: sink)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }

        #expect(sink.contains(flag.ref), "existing frame survives a cancelled sweep")
        let entries = try FileManager.default.contentsOfDirectory(atPath: sink.framesDir.path)
        #expect(entries.count == 1)
    }
}

// MARK: - export-status.json

@Suite("FrameExporter export-status.json", .serialized)
struct ExportStatusTests {

    @Test("export-status.json is written and decodes back with the expected fields")
    @MainActor
    func statusRoundTrips() async throws {
        let url = try exporterFixtureURL("dancer-full-body")
        let reachableFlag = try await fixtureFlag(for: url, atSeconds: 0.5)

        let baseDir = try tempBaseDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let store = FlagStore(baseDir: baseDir)
        store.add(reachableFlag)
        store.add(syntheticFlag(filename: "ghost-clip.mp4", headHash: "ff00ff00"))

        let sink = FolderDatasetSink(baseDir: baseDir)
        let exporter = FrameExporter(store: store)

        let statusURL = FrameExporter.statusURL(baseDir: baseDir)
        let ranAt = Date(timeIntervalSince1970: 1_700_000_000)
        let summary = try await exporter.sweep(
            sources: [url], into: sink, statusURL: statusURL, ranAt: ranAt
        )

        #expect(FileManager.default.fileExists(atPath: statusURL.path))

        let data = try Data(contentsOf: statusURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let status = try decoder.decode(FrameExporter.ExportStatus.self, from: data)

        #expect(status.version == FrameExporter.statusSchemaVersion)
        #expect(status.written == summary.written)
        #expect(status.skipped == summary.skipped)
        #expect(status.noFrame == summary.noFrame)
        #expect(status.ranAt == ranAt)
        #expect(status.unreachable.count == 1)
        #expect(status.unreachable.first?.displayFilename == "ghost-clip.mp4")
        #expect(status.unreachable.first?.pendingCount == 1)
    }
}
