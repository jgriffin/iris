import CoreGraphics
import CoreMedia
import Foundation
import Testing

@testable import Iris

// MARK: - Helpers

/// Resolve a bundled fixture clip, requiring it to exist (LFS-tracked).
private func fixtureURL(_ name: String, ext: String = "mp4") throws -> URL {
    try #require(
        Bundle.module.url(forResource: name, withExtension: ext),
        "Missing fixture \(name).\(ext) — run `git lfs install && git lfs pull` after clone."
    )
}

/// Copy a fixture into a fresh temp directory under a *different* filename, to
/// prove fingerprint identity is content-derived (survives rename/move).
private func copyToTemp(_ source: URL, named newName: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("iris-fp-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let dest = dir.appendingPathComponent(newName)
    try FileManager.default.copyItem(at: source, to: dest)
    return dest
}

/// A representative `Detection` exercising every nested Codable type:
/// box, keypoints, mask, skeleton, readout.
private func sampleDetection() -> Detection {
    Detection(
        boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
        label: "person",
        confidence: 0.87,
        keypoints: [
            Detection.Keypoint(name: "nose", position: CGPoint(x: 0.5, y: 0.6), confidence: 0.9),
            Detection.Keypoint(name: "left_shoulder", position: CGPoint(x: 0.4, y: 0.5), confidence: 0.8),
        ],
        mask: Detection.Mask(width: 64, height: 48),
        skeleton: Skeleton(edges: [Skeleton.Edge(from: "nose", to: "left_shoulder")]),
        readout: Readout(label: "joints", text: "2"),
        sourceModelID: "yolo26n"
    )
}

// MARK: - AssetFingerprint

@Suite("AssetFingerprint")
struct AssetFingerprintTests {

    @Test("same content at a different filename yields the same id")
    func contentIdentitySurvivesRename() async throws {
        let original = try fixtureURL("dancer-full-body")
        let renamed = try copyToTemp(original, named: "renamed-clip.mp4")
        defer { try? FileManager.default.removeItem(at: renamed.deletingLastPathComponent()) }

        let fpA = try await AssetFingerprint.compute(url: original)
        let fpB = try await AssetFingerprint.compute(url: renamed)

        #expect(fpA.id == fpB.id, "Content identity must survive a rename")
        #expect(fpA.filename != fpB.filename, "Filenames differ (metadata only)")
        #expect(fpA.headHash != nil, "Head-hash is computed by default")
    }

    @Test("two different clips get different ids")
    func differentClipsDifferentIds() async throws {
        let dancer = try fixtureURL("dancer-full-body")
        let clipboard = try fixtureURL("clipboard-blank-page")

        let fpA = try await AssetFingerprint.compute(url: dancer)
        let fpB = try await AssetFingerprint.compute(url: clipboard)

        #expect(fpA.id != fpB.id, "Distinct clips must produce distinct ids")
    }

    @Test("id is filesystem-safe")
    func idIsFilesystemSafe() async throws {
        let fp = try await AssetFingerprint.compute(url: try fixtureURL("dancer-full-body"))
        let allowed = CharacterSet(charactersIn: "0123456789abcdef-")
        #expect(fp.id.unicodeScalars.allSatisfy { allowed.contains($0) })
    }
}

// MARK: - FrameRef

@Suite("FrameRef")
struct FrameRefTests {

    @Test("PTS round-trips bit-exact through encode/decode")
    func ptsRoundTrip() throws {
        let fp = AssetFingerprint(
            filename: "x.mp4",
            byteSize: 12_345,
            durationSeconds: 4.2,
            headHash: "deadbeef"
        )
        // Non-trivial rational time that float storage would mangle.
        let pts = CMTime(value: 1001, timescale: 30000)
        let ref = FrameRef(asset: fp, pts: pts)

        let data = try JSONEncoder().encode(ref)
        let decoded = try JSONDecoder().decode(FrameRef.self, from: data)

        #expect(CMTimeCompare(decoded.pts, pts) == 0, "PTS must round-trip bit-exact")
        #expect(decoded.pts.value == 1001)
        #expect(decoded.pts.timescale == 30000)
        #expect(decoded == ref)
    }

    @Test("ptsMillis is deterministic")
    func ptsMillisDeterministic() {
        let fp = AssetFingerprint(filename: "x.mp4", byteSize: 1, durationSeconds: 1)
        let ref = FrameRef(asset: fp, pts: CMTime(value: 1500, timescale: 1000))
        #expect(ref.ptsMillis == 1500)
    }
}

// MARK: - Detection Codable

@Suite("Detection Codable")
struct DetectionCodableTests {

    @Test("representative detection round-trips losslessly")
    func detectionRoundTrip() throws {
        let detection = sampleDetection()
        let data = try JSONEncoder().encode(detection)
        let decoded = try JSONDecoder().decode(Detection.self, from: data)
        #expect(decoded == detection)
    }

    @Test("box-only detection round-trips (nil optionals)")
    func boxOnlyRoundTrip() throws {
        let detection = Detection(
            boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1),
            label: "rect",
            confidence: 1.0,
            sourceModelID: "mock"
        )
        let data = try JSONEncoder().encode(detection)
        let decoded = try JSONDecoder().decode(Detection.self, from: data)
        #expect(decoded == detection)
    }
}

// MARK: - FlagStore

@Suite("FlagStore")
struct FlagStoreTests {

    private func tempBaseDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-flagstore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeFlag() -> FrameFlag {
        let fp = AssetFingerprint(
            filename: "clip.mp4",
            byteSize: 999,
            durationSeconds: 3.0,
            headHash: "abc123"
        )
        let ref = FrameRef(asset: fp, pts: CMTime(value: 1001, timescale: 30000))
        return FrameFlag(
            ref: ref,
            detections: [sampleDetection()],
            modelID: "yolo26n",
            confidenceThreshold: 0.25,
            reason: .wrong,
            note: "false positive on the railing",
            flaggedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    @Test("a flag survives store reload on the same baseDir")
    @MainActor
    func reloadStability() throws {
        let baseDir = try tempBaseDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let flag = makeFlag()

        do {
            let store = FlagStore(baseDir: baseDir)
            store.add(flag)
            #expect(store.isFlagged(flag.ref))
            #expect(store.flags(for: flag.ref.asset).count == 1)
        }

        // Fresh store, same baseDir — the "reload same video → same flags" guarantee.
        let reloaded = FlagStore(baseDir: baseDir)
        let flags = reloaded.flags(for: flag.ref.asset)
        #expect(flags.count == 1)
        #expect(reloaded.isFlagged(flag.ref))
        #expect(flags.first == flag, "Reloaded flag must equal the original (lossless)")
    }

    @Test("toggle adds then removes")
    @MainActor
    func toggle() throws {
        let baseDir = try tempBaseDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let store = FlagStore(baseDir: baseDir)
        let flag = makeFlag()

        store.toggle(flag)
        #expect(store.isFlagged(flag.ref))

        store.toggle(flag)
        #expect(!store.isFlagged(flag.ref))
        #expect(store.flags(for: flag.ref.asset).isEmpty)
    }

    @Test("add dedups by FrameRef")
    @MainActor
    func addDedups() throws {
        let baseDir = try tempBaseDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let store = FlagStore(baseDir: baseDir)
        let flag = makeFlag()

        store.add(flag)
        // Same ref, different metadata — must replace, not duplicate.
        let updated = FrameFlag(ref: flag.ref, detections: [], reason: .nearMiss)
        store.add(updated)

        let flags = store.flags(for: flag.ref.asset)
        #expect(flags.count == 1)
        #expect(flags.first?.reason == .nearMiss)
    }
}
