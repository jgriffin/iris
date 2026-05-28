import CoreMedia
import Foundation

/// Canonical, reproducible address of a single playback frame:
/// `(AssetFingerprint, presentation-timestamp)`.
///
/// The presentation timestamp (PTS) is the *address*. It is stored as an
/// **exact `CMTime`** — a rational `{value, timescale}` — never a `Double`,
/// so there is no float drift and `seek(to: pts, tolerance: .zero)` round-trips
/// back to the same sample. `CMTime` is not `Codable`, so it is carried by the
/// nested ``CMTimeCodable`` wrapper which serializes all four `CMTime` fields
/// (`value`, `timescale`, `flags`, `epoch`) for a bit-exact round-trip.
///
/// ## PTS exactness decision (M7 doc · Opens · "PTS exactness vs currentTime()")
///
/// `Frame.timestamp` on the playback path is `AVPlayerItem.currentTime()` at
/// tick time, which can sit slightly off the true sample PTS. The open
/// question is whether `FrameRef` should **snap to the nearest sample PTS** on
/// construction, or **store the raw time** as given.
///
/// **DECISION for P1: store the raw `CMTime` verbatim; do NOT snap here.**
/// Snapping requires walking the asset's sample table (an `AVAssetReader` /
/// `AVSampleCursor` pass) — that machinery is the extraction path being built
/// in P3. Doing it here in P1 would either duplicate that path or fake it.
/// Re-seek with `.zero` tolerance already lands on the frame whose PTS is the
/// largest ≤ the requested time, so a raw `currentTime()` that sits between
/// samples still resolves deterministically to *a* concrete frame. P3 will
/// validate snapping against a fixture and, if the adjacent-frame risk is
/// real, introduce a `snapped(in:)` constructor on the extraction side.
///
/// // M7·P3: validate raw-vs-snap against a fixture; add `FrameRef.snapped(in:)`
/// // on the extraction path if `.zero`-tolerance re-seek can land on an
/// // adjacent frame for a mid-sample `currentTime()`.
public struct FrameRef: Sendable, Hashable, Codable {

    /// Content identity of the asset this frame belongs to.
    public let asset: AssetFingerprint

    /// Exact presentation timestamp of the frame within the asset's timeline.
    public let pts: CMTime

    public init(asset: AssetFingerprint, pts: CMTime) {
        self.asset = asset
        self.pts = pts
    }

    /// Deterministic integer-millisecond rendering of `pts`, used to build
    /// stable, collision-resistant extraction filenames
    /// (`<asset.id>_<ptsMillis>.png`). Derived from the rational time, then
    /// rounded — same `pts` always yields the same value.
    public var ptsMillis: Int64 {
        let seconds = CMTimeGetSeconds(pts)
        guard seconds.isFinite else { return 0 }
        return Int64((seconds * 1000).rounded())
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case asset
        case pts
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        asset = try container.decode(AssetFingerprint.self, forKey: .asset)
        pts = try container.decode(CMTimeCodable.self, forKey: .pts).cmTime
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(asset, forKey: .asset)
        try container.encode(CMTimeCodable(pts), forKey: .pts)
    }

    /// `Codable` shadow of `CMTime` — `CMTime` itself isn't `Codable`. Carries
    /// all four fields so the round-trip is bit-exact (a non-trivial
    /// `{value: 1001, timescale: 30000}` survives encode→decode with
    /// `CMTimeCompare == 0`).
    public struct CMTimeCodable: Sendable, Hashable, Codable {
        public let value: Int64
        public let timescale: Int32
        public let flags: UInt32
        public let epoch: Int64

        public init(_ time: CMTime) {
            value = time.value
            timescale = time.timescale
            flags = time.flags.rawValue
            epoch = time.epoch
        }

        public var cmTime: CMTime {
            CMTime(
                value: value,
                timescale: timescale,
                flags: CMTimeFlags(rawValue: flags),
                epoch: epoch
            )
        }
    }
}
