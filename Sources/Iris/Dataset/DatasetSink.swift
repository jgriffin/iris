import Foundation

/// Destination for extracted dataset frames: where the headless
/// `DatasetBuilder` writes each flagged frame's PNG image.
///
/// v1 ships `FolderDatasetSink` (a `<baseDir>/iris-dataset/frames/` directory).
/// The protocol leaves room for the iCloud / S3 sinks named in BRIEF §6 without
/// building them — they slot in by conforming.
///
/// ## No per-image sidecar
///
/// The dataset folder is just `frames/*.png`. There is no per-image `.json`
/// sidecar: annotations are recovered from the `FlagStore` (keyed by the same
/// content fingerprint) and a future `COCOExporter` (P4) will emit a single
/// dataset-level manifest, not per-frame fragments.
///
/// ## Concurrency
///
/// `Sendable` so a builder can hold one across `await` points. `contains` is
/// synchronous (a cheap existence check — a directory scan for the folder sink)
/// so the dedup gate doesn't force a suspension per frame; `write` is
/// `async throws` because real sinks (iCloud/S3) will do I/O off the calling
/// actor.
public protocol DatasetSink: Sendable {

    /// Whether this sink already holds the frame at `ref`. The dedup gate:
    /// `DatasetBuilder` skips extraction (the expensive re-seek + decode) when
    /// this returns `true`, making re-runs cheap and extraction resumable.
    ///
    /// Dedup keys on the **rename-stable suffix** of the export filename
    /// (`_<fingerprintID>_<ptsMillis>.png`), not the full name: the cosmetic
    /// `sourceNameHash` prefix shifts if the source video is renamed, so the
    /// folder sink matches on suffix to avoid double-exporting a frame that was
    /// already written under a pre-rename prefix.
    func contains(_ ref: FrameRef) -> Bool

    /// Persist one extracted frame as PNG `image` bytes, keyed by `ref`. The
    /// sink derives a stable name from `ref` so a re-run overwrites in place
    /// rather than duplicating.
    func write(image: Data, for ref: FrameRef) async throws
}
