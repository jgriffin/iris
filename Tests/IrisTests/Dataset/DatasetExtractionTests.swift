import CoreGraphics
import CoreMedia
import Foundation
import Testing

@testable import Iris

// MARK: - Helpers

/// Resolve a bundled fixture clip, requiring it to exist (LFS-tracked).
private func extractionFixtureURL(_ name: String, ext: String = "mp4") throws -> URL {
    try #require(
        Bundle.module.url(forResource: name, withExtension: ext),
        "Missing fixture \(name).\(ext) — run `git lfs install && git lfs pull` after clone."
    )
}

/// A fresh temp dir for a sink's `baseDir`.
private func tempBaseDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("iris-extract-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Open the fixture, seek near `seconds`, and return the *canonical* `FrameRef`
/// for the frame the player actually lands on (its exact sample PTS) plus its
/// fingerprint. This mirrors how the flagging UI captures a `FrameRef` from a
/// live frame, and gives the extraction test a PTS that genuinely exists.
private func canonicalFlag(
    for url: URL,
    nearSeconds seconds: Double,
    reason: FlagReason = .wrong
) async throws -> FrameFlag {
    let fingerprint = try await AssetFingerprint.compute(url: url)

    let source = PlaybackSource(url: url)
    defer { Task { await source.invalidate() } }

    var iterator = source.frames.makeAsyncIterator()
    try await source.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    let frame = try #require(await iterator.next(), "fixture should decode a frame")

    let ref = FrameRef(asset: fingerprint, pts: frame.timestamp)
    let detection = Detection(
        boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
        label: "person",
        confidence: 0.5,
        sourceModelID: "test"
    )
    return FrameFlag(
        ref: ref,
        detections: [detection],
        modelID: "test",
        confidenceThreshold: 0.25,
        reason: reason,
        note: "extraction fixture"
    )
}

/// Minimal PNG validity check: 8-byte signature.
private func isPNG(_ data: Data) -> Bool {
    let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    return data.count > signature.count && Array(data.prefix(signature.count)) == signature
}

// MARK: - Extraction

@Suite("DatasetBuilder extraction")
struct DatasetExtractionTests {

    @Test("extracts to <sourceNameHash>_<id>_<ptsMillis>.png with no .json sidecar")
    func extractsToDeterministicNames() async throws {
        let url = try extractionFixtureURL("dancer-full-body")
        let flag = try await canonicalFlag(for: url, nearSeconds: 0.5)

        let baseDir = try tempBaseDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let sink = FolderDatasetSink(baseDir: baseDir)

        let summary = try await DatasetBuilder().extract(
            flags: [flag], from: url, into: sink
        )
        #expect(summary.written == 1)
        #expect(summary.skipped == 0)

        // Filename scheme: <sourceNameHash>_<asset.id>_<ptsMillis>.png. The
        // suffix is rename-stable; the prefix is a cosmetic hash of the source
        // filename.
        let entries = try FileManager.default.contentsOfDirectory(atPath: sink.framesDir.path)
        #expect(entries.count == 1, "exactly one artifact per frame (the PNG)")

        let name = try #require(entries.first)
        let suffix = "_\(flag.ref.asset.id)_\(flag.ref.ptsMillis).png"
        #expect(name.hasSuffix(suffix), "name must end in the rename-stable identity suffix")

        let prefix = String(name.dropLast(suffix.count))
        #expect(prefix.count == 8, "sourceNameHash prefix is 8 hex chars")
        #expect(
            prefix.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdef").contains($0) },
            "sourceNameHash prefix is lowercase hex"
        )

        // No per-image sidecar of any kind.
        #expect(!entries.contains { $0.hasSuffix(".json") }, "no .json sidecar should be written")

        // The sink's own URL derivation agrees with what landed on disk.
        #expect(sink.imageURL(for: flag.ref).lastPathComponent == name)
        #expect(FileManager.default.fileExists(atPath: sink.imageURL(for: flag.ref).path))
    }

    @Test("extracted image is a valid, non-empty PNG (round-trip)")
    func extractedImageIsValidPNG() async throws {
        let url = try extractionFixtureURL("dancer-full-body")
        let flag = try await canonicalFlag(for: url, nearSeconds: 0.5)

        let baseDir = try tempBaseDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let sink = FolderDatasetSink(baseDir: baseDir)

        try await DatasetBuilder().extract(flags: [flag], from: url, into: sink)

        let data = try Data(contentsOf: sink.imageURL(for: flag.ref))
        #expect(!data.isEmpty)
        #expect(isPNG(data), "Extracted frame must be a valid PNG")
    }

    @Test("dedup is rename-stable: a frame present under a different prefix is skipped")
    func dedupSurvivesSourceRename() async throws {
        let url = try extractionFixtureURL("dancer-full-body")
        let flag = try await canonicalFlag(for: url, nearSeconds: 0.5)

        let baseDir = try tempBaseDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let sink = FolderDatasetSink(baseDir: baseDir)

        // First export under the real source name.
        let first = try await DatasetBuilder().extract(flags: [flag], from: url, into: sink)
        #expect(first.written == 1)

        // Simulate a source rename: same content + PTS (rename-stable suffix),
        // but a *different* filename ⇒ a different cosmetic sourceNameHash
        // prefix. The fingerprint id is unchanged (content-derived), so the
        // suffix matches and the frame must be treated as already-present.
        let renamedFingerprint = AssetFingerprint(
            filename: "totally-different-name.mp4",
            byteSize: flag.ref.asset.byteSize,
            durationSeconds: flag.ref.asset.durationSeconds,
            headHash: flag.ref.asset.headHash
        )
        let renamedRef = FrameRef(asset: renamedFingerprint, pts: flag.ref.pts)
        #expect(renamedFingerprint.id == flag.ref.asset.id, "id is rename-stable")

        // contains() must match on the suffix even though the prefix differs.
        #expect(sink.contains(renamedRef), "frame under a pre-rename prefix counts as present")

        let renamedFlag = FrameFlag(
            ref: renamedRef,
            detections: flag.detections,
            modelID: flag.modelID,
            confidenceThreshold: flag.confidenceThreshold,
            reason: flag.reason,
            note: flag.note
        )
        let second = try await DatasetBuilder().extract(flags: [renamedFlag], from: url, into: sink)
        #expect(second.written == 0, "rename must not double-export")
        #expect(second.skipped == 1)

        // Still exactly one PNG on disk.
        let entries = try FileManager.default.contentsOfDirectory(atPath: sink.framesDir.path)
        #expect(entries.count == 1)
    }

    @Test("re-running extraction writes nothing (contains-skip dedup)")
    func reRunIsDedupSkip() async throws {
        let url = try extractionFixtureURL("dancer-full-body")
        let flag = try await canonicalFlag(for: url, nearSeconds: 0.5)

        let baseDir = try tempBaseDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let sink = FolderDatasetSink(baseDir: baseDir)

        let first = try await DatasetBuilder().extract(flags: [flag], from: url, into: sink)
        #expect(first.written == 1)

        // Second pass over the same flag: the PNG already exists, so the
        // builder skips the re-seek + decode entirely.
        let second = try await DatasetBuilder().extract(flags: [flag], from: url, into: sink)
        #expect(second.written == 0)
        #expect(second.skipped == 1)
    }

    @Test("contains() reflects whether a frame is on disk")
    func containsReflectsDisk() async throws {
        let url = try extractionFixtureURL("dancer-full-body")
        let flag = try await canonicalFlag(for: url, nearSeconds: 0.5)

        let baseDir = try tempBaseDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let sink = FolderDatasetSink(baseDir: baseDir)

        #expect(!sink.contains(flag.ref))
        try await DatasetBuilder().extract(flags: [flag], from: url, into: sink)
        #expect(sink.contains(flag.ref))
    }
}
