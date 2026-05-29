import Foundation
import os

/// v1 `DatasetSink`: writes extracted frames as files under an injected
/// `baseDir`, mirroring `FlagStore`'s no-hardcoded-paths discipline (the app
/// passes its Documents dir; tests pass a temp dir).
///
/// ## Layout
///
/// ```
/// <baseDir>/iris-dataset/frames/<sourceNameHash>_<fingerprint.id>_<ptsMillis>.png
/// ```
///
/// The name has three segments:
///
/// - `sourceNameHash` — a short hash of the source *filename* (cosmetic
///   grouping prefix only; collision-tolerant — two videos sharing a name is
///   fine). It lets a human eyeball which clip a frame came from in a directory
///   listing, and shifts if the source is renamed.
/// - `fingerprint.id` + `ptsMillis` — the **rename-stable** identity suffix,
///   derived purely from content + PTS. The same frame of the same content
///   always produces the same suffix regardless of the source's name.
///
/// `contains` matches on that suffix (not the full name) so a frame already
/// exported under a *pre-rename* prefix still counts as present — see
/// `contains(_:)`.
///
/// The `frames/` directory sits next to `FlagStore`'s `flags/` directory under
/// the shared `iris-dataset/` root — one browsable dataset folder in Files.app.
public struct FolderDatasetSink: DatasetSink {

    /// Injected root. Frames live under `<baseDir>/iris-dataset/frames/`.
    private let baseDir: URL

    private static let logger = Logger(subsystem: "iris.dataset", category: "FolderDatasetSink")

    /// - Parameter baseDir: app-injected root directory. Frames are written
    ///   under `<baseDir>/iris-dataset/frames/`. The library never hardcodes
    ///   this — pass the app's Documents dir (or a temp dir in tests), exactly
    ///   as `FlagStore` does.
    public init(baseDir: URL) {
        self.baseDir = baseDir
    }

    // MARK: - Paths

    /// `<baseDir>/iris-dataset/frames/`.
    public var framesDir: URL {
        baseDir
            .appendingPathComponent("iris-dataset", isDirectory: true)
            .appendingPathComponent("frames", isDirectory: true)
    }

    /// Length (hex chars) of the cosmetic `sourceNameHash` prefix.
    static let sourceNameHashLength = 8

    /// Cosmetic grouping prefix: a short hash of the source *filename*. Reuses
    /// `AssetFingerprint.shortHex` (single source of truth for the hashing
    /// recipe) so the prefix is derived the same way everywhere.
    private func sourceNameHash(for ref: FrameRef) -> String {
        AssetFingerprint.shortHex(of: ref.asset.filename, hexChars: Self.sourceNameHashLength)
    }

    /// Rename-stable identity suffix (including extension):
    /// `_<fingerprint.id>_<ptsMillis>.png`. The `contains` dedup gate matches on
    /// exactly this — it does not include the cosmetic `sourceNameHash` prefix.
    private func identitySuffix(for ref: FrameRef) -> String {
        "_\(ref.asset.id)_\(ref.ptsMillis).png"
    }

    /// `<framesDir>/<sourceNameHash>_<asset.id>_<ptsMillis>.png`.
    public func imageURL(for ref: FrameRef) -> URL {
        let name = "\(sourceNameHash(for: ref))\(identitySuffix(for: ref))"
        return framesDir.appendingPathComponent(name, isDirectory: false)
    }

    // MARK: - DatasetSink

    /// Dedup gate keyed on the **rename-stable suffix**, not the full filename.
    ///
    /// The cosmetic `sourceNameHash` prefix shifts if the source video is
    /// renamed, but `_<fingerprintID>_<ptsMillis>.png` is rename-stable (derived
    /// purely from content + PTS). So a frame already exported under a
    /// pre-rename prefix must still count as present — otherwise a rename would
    /// silently double-export every frame. We therefore scan the `frames/`
    /// directory once and report `true` if any entry ends in this suffix.
    public func contains(_ ref: FrameRef) -> Bool {
        let suffix = identitySuffix(for: ref)
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                atPath: framesDir.path
            )
        else {
            return false  // no frames/ dir yet ⇒ nothing contained
        }
        return entries.contains { $0.hasSuffix(suffix) }
    }

    /// Write the PNG atomically under the deterministic name, creating
    /// `frames/` on first write.
    public func write(image: Data, for ref: FrameRef) async throws {
        try FileManager.default.createDirectory(
            at: framesDir,
            withIntermediateDirectories: true
        )
        // Atomic write so a crash mid-write can't leave a truncated PNG that
        // would then fool `contains` into skipping a real re-extraction.
        try image.write(to: imageURL(for: ref), options: .atomic)
    }
}
