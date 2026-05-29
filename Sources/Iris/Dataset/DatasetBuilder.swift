@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import os

/// Headless batch extractor: the deferred, expensive half of the M7 loop.
///
/// Flagging records tiny `(asset, pts)` addresses while scrubbing; *this* turns
/// those addresses back into pixels — re-seeking each flagged PTS with `.zero`
/// tolerance, decoding the frame, encoding it to PNG, and writing the image
/// through a `DatasetSink`. It is the consumer `PlaybackSource`'s headless
/// `TaskTickDriver` was built for (no view, no display link).
///
/// ## Resumable / dedup
///
/// Before the costly re-seek + decode, the builder asks `sink.contains(ref)`
/// and **skips** frames the sink already holds. Deterministic naming
/// (`<asset.id>_<ptsMillis>`) makes that a plain existence check, so a re-run
/// over the same flags writes nothing new and a partially-completed run resumes
/// from where it stopped.
///
/// ## PTS snap decision (resolves the `// M7·P3:` tripwire on `FrameRef`)
///
/// P1 stored `Frame.timestamp` (`AVPlayerItem.currentTime()`) verbatim, leaving
/// open whether extraction needs to *snap* to the nearest sample PTS so re-seek
/// lands exactly. **P3's resolution: no separate snap pass is needed.**
/// `PlaybackSource.seek(to:)` already seeks with `toleranceBefore/After: .zero`,
/// which AVF resolves to the sample whose PTS is the largest ≤ the requested
/// time, and `emitOneShotFrame()` then stamps the emitted `Frame.timestamp`
/// with `playerItem.currentTime()` — i.e. that resolved sample's exact PTS.
/// So the frame we decode *is* the canonical sample for the requested address;
/// a mid-sample `currentTime()` recorded at flag time deterministically resolves
/// to the same concrete frame on every re-seek. We therefore do **not** add a
/// `FrameRef.snapped(in:)` constructor: the file is named from the stored
/// (requested) `ref` so dedup stays stable, while the *pixels* come from the
/// `.zero`-tolerance-resolved sample. The extraction test asserts this
/// round-trips to a valid, non-empty PNG on a real fixture.
public struct DatasetBuilder: Sendable {

    /// Outcome of extracting a single flag.
    public enum FrameOutcome: Sendable, Equatable {
        /// A PNG was written for this address.
        case written
        /// Skipped — the sink already held this frame (`contains` was true).
        case skipped
        /// The re-seek produced no decodable frame (e.g. an out-of-range or
        /// unreadable PTS). Not fatal — the batch continues.
        case noFrame
    }

    /// Summary of a batch run.
    public struct Summary: Sendable, Equatable {
        public var written: Int
        public var skipped: Int
        public var noFrame: Int

        public init(written: Int = 0, skipped: Int = 0, noFrame: Int = 0) {
            self.written = written
            self.skipped = skipped
            self.noFrame = noFrame
        }
    }

    private let encoder: PixelBufferPNGEncoder
    private static let logger = Logger(subsystem: "iris.dataset", category: "DatasetBuilder")

    public init(encoder: PixelBufferPNGEncoder = PixelBufferPNGEncoder()) {
        self.encoder = encoder
    }

    // MARK: - Batch

    /// Extract every flag for one asset from the video at `url`, writing the
    /// PNG through `sink` and skipping anything `sink` already holds.
    ///
    /// One `PlaybackSource` (default headless `TaskTickDriver`) is built for
    /// the whole batch and reused across seeks. Flags whose frame is already
    /// present are skipped *without* a seek.
    ///
    /// - Parameters:
    ///   - flags: the flags to extract (typically `flagStore.flags(for:)`).
    ///   - url: the on-disk video to re-seek (the asset the flags belong to).
    ///   - sink: destination for the extracted PNGs.
    /// - Returns: a `Summary` of written / skipped / no-frame counts.
    @discardableResult
    public func extract(
        flags: [FrameFlag],
        from url: URL,
        into sink: some DatasetSink
    ) async throws -> Summary {
        var summary = Summary()

        // Partition cheaply: skip already-present frames before touching AVF.
        let pending = flags.filter { !sink.contains($0.ref) }
        summary.skipped = flags.count - pending.count
        guard !pending.isEmpty else { return summary }

        let source = PlaybackSource(url: url)
        defer { Task { await source.invalidate() } }

        // `seek(to:)` yields the resolved frame on `source.frames` via
        // `emitOneShotFrame()`. Drive an iterator so each seek's frame is
        // consumed in order, one at a time.
        var iterator = source.frames.makeAsyncIterator()

        for flag in pending {
            switch try await extractOne(flag: flag, source: source, iterator: &iterator, sink: sink) {
            case .written: summary.written += 1
            case .skipped: summary.skipped += 1
            case .noFrame: summary.noFrame += 1
            }
        }

        return summary
    }

    /// Seek to one flag's PTS, grab the resolved frame, encode + write it.
    private func extractOne(
        flag: FrameFlag,
        source: PlaybackSource,
        iterator: inout AsyncStream<Frame>.AsyncIterator,
        sink: some DatasetSink
    ) async throws -> FrameOutcome {
        let ref = flag.ref

        // Re-check inside the loop in case the sink changed under us; keeps the
        // dedup gate authoritative even if `extract` is called concurrently.
        if sink.contains(ref) { return .skipped }

        // `.zero`-tolerance seek (see PlaybackSource.seek); emits one frame.
        try await source.seek(to: ref.pts)

        guard let frame = await iterator.next() else {
            Self.logger.error("extractOne: no frame after seek for \(ref.ptsMillis)")
            return .noFrame
        }

        let image = try encoder.pngData(from: frame.pixelBuffer)
        try await sink.write(image: image, for: ref)
        return .written
    }
}
