import AVFoundation
import CryptoKit
import Foundation

/// Content-derived identity for a playback asset, used as the dataset-scoped
/// key for flag storage and extraction naming.
///
/// **Why not the URL.** `AssetID.raw = url.absoluteString` is the playback
/// *session* handle — it breaks the moment a file is moved or renamed. M7's
/// guarantee is "reload the same video → same flags," which means the key
/// must survive a path change. So the identity is derived from **content**
/// (`byteSize` + `durationSeconds` + an optional head-hash), never from the
/// path. `filename` is retained as *metadata only* — handy for display and
/// debugging — and is deliberately excluded from `id`.
///
/// **Collision posture.** size + duration alone is strong but not unique. The
/// optional `headHash` (SHA-256 of the first ~1 MB) is the safety valve and is
/// computed by `compute(url:)` by default — reading 1 MB is cheap next to
/// decoding video, so it stays on. `id` folds the head-hash in when present.
///
/// `AssetFingerprint` lives *alongside* `AssetID`, not replacing it: `AssetID`
/// stays the playback-session handle, this is the dataset persistence key.
/// (M7 doc · Opens · "AssetID.raw vs AssetFingerprint".)
public struct AssetFingerprint: Sendable, Hashable, Codable {

    /// Original filename (last path component). **Metadata only** — display
    /// and debugging. Intentionally NOT part of `id` so a rename preserves
    /// identity.
    public let filename: String

    /// File size in bytes (via `FileManager` attributes).
    public let byteSize: Int64

    /// Asset duration in seconds (via `AVAsset.load(.duration)`).
    public let durationSeconds: Double

    /// Lowercase-hex SHA-256 of the first ~1 MB of the file, or `nil` if not
    /// computed. Folded into `id` when present for collision safety.
    public let headHash: String?

    /// Number of leading bytes hashed by `compute(url:)` for `headHash`.
    public static let headHashByteCount = 1 << 20  // 1 MiB

    public init(
        filename: String,
        byteSize: Int64,
        durationSeconds: Double,
        headHash: String? = nil
    ) {
        self.filename = filename
        self.byteSize = byteSize
        self.durationSeconds = durationSeconds
        self.headHash = headHash
    }

    /// Filesystem-safe stable identity key derived purely from **content**:
    /// `byteSize`, `durationSeconds` (quantized to milliseconds so float
    /// formatting doesn't jitter the key), and `headHash` when present. Two
    /// copies of the same bytes at different paths/names produce the SAME
    /// `id`. Safe to use directly as a filename (only `[0-9a-f-]`).
    public var id: String {
        // Quantize duration to integer milliseconds: `AVAsset.load(.duration)`
        // returns the same rational time for the same file, but rendering a
        // Double can vary across platforms/locales — milliseconds give a
        // stable, path-safe token.
        let durationMillis = Int64((durationSeconds * 1000).rounded())
        var key = "\(byteSize)-\(durationMillis)"
        if let headHash, !headHash.isEmpty {
            key += "-\(headHash)"
        }
        return key
    }

    /// Compute a fingerprint for the file at `url`.
    ///
    /// - File size: `FileManager` attributes (`.size`).
    /// - Duration: `try await AVURLAsset(url:).load(.duration)`.
    /// - Head-hash: SHA-256 over the first ``headHashByteCount`` bytes (or the
    ///   whole file if shorter). Reads a bounded prefix only — never the whole
    ///   video — so it stays cheap on large files.
    public static func compute(url: URL) async throws -> AssetFingerprint {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let byteSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)

        let headHash = try Self.computeHeadHash(url: url)

        return AssetFingerprint(
            filename: url.lastPathComponent,
            byteSize: byteSize,
            durationSeconds: durationSeconds.isFinite ? durationSeconds : 0,
            headHash: headHash
        )
    }

    /// SHA-256 (lowercase hex) of up to ``headHashByteCount`` leading bytes.
    /// Uses a file handle so only the prefix is read into memory.
    private static func computeHeadHash(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: headHashByteCount) ?? Data()
        let digest = SHA256.hash(data: prefix)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
