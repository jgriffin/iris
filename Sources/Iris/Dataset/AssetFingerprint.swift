import AVFoundation
import CryptoKit
import Foundation

/// Content-derived identity for a playback asset, used as the dataset-scoped
/// key for flag storage and extraction naming.
///
/// **Why not the URL or the name.** `AssetID.raw = url.absoluteString` is the
/// playback *session* handle — it breaks the moment a file is moved or renamed.
/// M7's guarantee is "reload the same video → same flags," which means the key
/// must survive a path *and* a name change. So the identity is derived purely
/// from **content** (`byteSize` + `durationSeconds` + `headHash`), never from
/// the path or the filename. `filename` is retained as *metadata only* — handy
/// for display and debugging — and is deliberately excluded from `id`.
///
/// **Collision posture.** size + duration alone is strong but not unique. The
/// `headHash` (SHA-256 of the first ~1 MB) is the safety valve and is
/// **mandatory**: it is what makes the fingerprint edit-sensitive — trimming
/// from the middle of a clip shifts the duration, trimming from the head shifts
/// the head-hash, and either way the `id` changes. Reading 1 MB is cheap next
/// to decoding video, so it always runs.
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

    /// Lowercase-hex SHA-256 of the first ~1 MB of the file. **Mandatory** —
    /// it is load-bearing in `id` for collision safety and edit-sensitivity.
    public let headHash: String

    /// Number of leading bytes hashed by `compute(url:)` for `headHash`.
    public static let headHashByteCount = 1 << 20  // 1 MiB

    public init(
        filename: String,
        byteSize: Int64,
        durationSeconds: Double,
        headHash: String
    ) {
        self.filename = filename
        self.byteSize = byteSize
        self.durationSeconds = durationSeconds
        self.headHash = headHash
    }

    /// Filesystem-safe stable identity key derived purely from **content** —
    /// never the path or filename.
    ///
    /// ## Recipe
    ///
    /// 1. Build a canonical string `"<byteSize>:<durationMillis>:<headHashHex>"`,
    ///    where `durationMillis = round(durationSeconds * 1000)` (quantizing to
    ///    integer milliseconds so `Double` formatting can't jitter the key
    ///    across platforms/locales).
    /// 2. SHA-256 that UTF-8 string.
    /// 3. Take the **first 16 hex characters** (8 bytes) of the digest.
    ///
    /// The result is a short, fixed-width, filesystem-safe token (only
    /// `[0-9a-f]`) used directly as the `<fingerprint.id>.json` flag filename
    /// and as the extraction-filename middle segment. Two copies of the same
    /// bytes at different paths/names produce the SAME `id`; a content edit
    /// (different size, duration, or head bytes) produces a different one.
    public var id: String {
        let durationMillis = Int64((durationSeconds * 1000).rounded())
        let canonical = "\(byteSize):\(durationMillis):\(headHash)"
        return Self.shortHex(of: canonical, hexChars: 16)
    }

    /// Single source of truth for "stable short hex of a string": SHA-256 the
    /// UTF-8 bytes, render lowercase hex, and take the leading `hexChars`
    /// characters. Used by `id` here and by the export-filename `sourceNameHash`
    /// in the dataset sink, so the hashing recipe lives in exactly one place.
    static func shortHex(of string: String, hexChars: Int) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(hexChars))
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
