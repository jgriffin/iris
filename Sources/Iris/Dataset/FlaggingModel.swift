import CoreMedia
import Foundation
import Observation

/// The `@Observable` brain behind M7's flagging UI: it owns the
/// current-asset fingerprint, answers "is the current frame flagged?", and
/// toggles / lists / jumps-to flags by talking to a ``FlagStore`` (the
/// persistence) and a ``FlaggingSource`` (the live playhead + detections).
///
/// **Two collaborators, two roles.** The ``FlagStore`` is the on-disk truth
/// (per-asset JSON, injected `baseDir`); the ``FlaggingSource`` is the live
/// playback seam (current PTS, visible detections, jump). The model is the
/// thin coordinator between them — the built-in views (``FlagButton``,
/// ``FlagMarkerStrip``, ``FlaggedFramesList``) read it and never touch the
/// store or source directly. UI placement lives in the app (M4 doctrine:
/// reusable logic in the library, thin built-in views, app owns placement).
///
/// **`source` is `unowned`.** In the demo the coordinator (the
/// `FlaggingSource`) outlives the model and effectively owns it via the same
/// view's `@State`; a strong reference here would form a retain cycle. The
/// source is guaranteed alive for the model's lifetime, so `unowned` is safe
/// and avoids the optional-chaining noise of `weak`.
@MainActor
@Observable
public final class FlaggingModel {

    /// On-disk flag persistence. Reads/writes go through here so flags
    /// survive reloads and the same video resolves to the same flag file.
    private let store: FlagStore

    /// Live playback seam — the playhead, the visible detections, and jump.
    /// `unowned` to avoid a cycle with the coordinator (see type doc).
    @ObservationIgnored private unowned let source: FlaggingSource

    /// Content fingerprint of the active asset, or `nil` when no source is
    /// loaded. Set via ``setAsset(url:)`` after every source swap; cleared
    /// when there is no source. All flag operations require it.
    public private(set) var asset: AssetFingerprint?

    /// Tolerance for matching the live playhead to a stored flag PTS: half a
    /// frame at 30 fps. The live `currentTime` (from `AVPlayer`'s periodic
    /// observer) rarely lands exactly on a stored sample PTS, so exact
    /// equality is too brittle — a flag set at one tick wouldn't read as
    /// "current" a tick later. A ½-frame window snaps the current frame to
    /// its flag without bleeding into the neighbor (a full frame is
    /// `1/30 s`; half is `1/60 s`).
    static let matchTolerance = CMTime(value: 1, timescale: 60)

    /// - Parameters:
    ///   - store: on-disk flag persistence (app injects its Documents-dir
    ///     `FlagStore`; tests inject a temp-dir one).
    ///   - source: the live playback seam — usually a
    ///     `PlaybackDetectionCoordinator`, held `unowned`.
    public init(store: FlagStore, source: FlaggingSource) {
        self.store = store
        self.source = source
    }

    // MARK: - Asset lifecycle

    /// Compute and store the fingerprint of the asset at `url`. Call after
    /// every source swap (fixture load and external pick) with the same URL
    /// used to build the `PlaybackSource`. On failure, clears `asset` (the
    /// UI then disables flagging rather than flagging against a stale
    /// fingerprint).
    public func setAsset(url: URL) async {
        do {
            asset = try await AssetFingerprint.compute(url: url)
        } catch {
            asset = nil
        }
    }

    /// Clear the active asset (no source loaded). Flagging controls disable.
    public func clearAsset() {
        asset = nil
    }

    // MARK: - Reading

    /// Flags for the current asset, sorted by presentation time so the
    /// marker strip and the list render in playback order. Empty when no
    /// asset is loaded.
    public var currentFlags: [FrameFlag] {
        guard let asset else { return [] }
        return store.flags(for: asset).sorted { $0.ref.ptsMillis < $1.ref.ptsMillis }
    }

    /// Whether the current playhead sits on a flagged frame, within
    /// ``matchTolerance``. Drives the bookmark toggle's filled/empty state.
    public func isCurrentFlagged() -> Bool {
        currentFlag() != nil
    }

    // MARK: - Mutating

    /// Toggle a flag at the current playhead. If a flag already exists within
    /// ``matchTolerance``, remove it; otherwise add a new one carrying the
    /// detections visible right now, the first non-empty `sourceModelID` as
    /// `modelID`, and the supplied `reason` / `note`.
    ///
    /// No-op when there is no asset or no current PTS (the UI disables the
    /// control in that case, but the guard keeps the model honest).
    ///
    /// `confidenceThreshold` is `nil` in P2 — surfacing the live threshold
    /// needs a tuning-side accessor that doesn't exist yet (tracked in
    /// M7.md Opens).
    public func toggleCurrent(reason: FlagReason = .wrong, note: String? = nil) {
        guard let asset, let pts = source.currentPTS else { return }

        if let existing = currentFlag() {
            store.remove(existing.ref)
            return
        }

        let detections = source.currentDetections()
        let flag = FrameFlag(
            ref: FrameRef(asset: asset, pts: pts),
            detections: detections,
            modelID: detections.first { !$0.sourceModelID.isEmpty }?.sourceModelID,
            confidenceThreshold: nil,
            reason: reason,
            note: note
        )
        store.add(flag)
    }

    /// Jump the playhead to `flag`'s exact stored PTS (fire-and-forget seek).
    public func jump(to flag: FrameFlag) {
        source.seek(to: flag.ref.pts)
    }

    /// Remove `flag` from the store.
    public func remove(_ flag: FrameFlag) {
        store.remove(flag.ref)
    }

    // MARK: - Private

    /// The current-asset flag whose PTS is within ``matchTolerance`` of the
    /// live playhead, or `nil`. The single source of truth for both
    /// "is current flagged?" and "which flag does toggle remove?".
    private func currentFlag() -> FrameFlag? {
        guard let asset, let pts = source.currentPTS else { return nil }
        return store.flags(for: asset).first { flag in
            CMTimeAbsoluteValue(flag.ref.pts - pts) <= Self.matchTolerance
        }
    }
}

// MARK: - Preview / test support

#if DEBUG

/// AVF-free, coordinator-free ``FlaggingSource`` for `#Preview`s (and a
/// convenient double for tests). Mirrors `MockScrubberModel`'s style in
/// [`Scrubber.swift`](../Playback/Scrubber.swift): plain stored state plus a
/// recorded action so a test can assert "jump seeked to exactly this PTS"
/// without any playback machinery.
///
/// `@MainActor` to match the protocol's isolation; a `final class` so it can
/// be held `unowned` by the model.
@MainActor
public final class MockFlaggingSource: FlaggingSource {

    /// Settable playhead. `nil` models "no source loaded".
    public var currentPTS: CMTime?

    /// Canned detections returned by ``currentDetections()`` — captured into
    /// a flag on `toggleCurrent`.
    public var detections: [Detection]

    /// The last PTS passed to ``seek(to:)``, for jump-to-flag assertions.
    public private(set) var lastSeekTarget: CMTime?

    public init(currentPTS: CMTime? = .zero, detections: [Detection] = []) {
        self.currentPTS = currentPTS
        self.detections = detections
    }

    public func currentDetections() -> [Detection] { detections }

    public func seek(to pts: CMTime) {
        lastSeekTarget = pts
        currentPTS = pts
    }
}

extension FlaggingModel {

    /// Set `asset` directly without a fingerprint compute — preview/test
    /// seam so a double can put the model on a known asset synchronously.
    func setAssetForTesting(_ asset: AssetFingerprint?) {
        self.asset = asset
    }

    /// Build a model wired to an in-temp-dir ``FlagStore`` pre-seeded with
    /// `flags`, plus the supplied (or a default) ``MockFlaggingSource``.
    /// Returns the model and the source so a `#Preview` can mutate the
    /// playhead live. The asset is taken from the first flag's ref (so
    /// `currentFlags` is non-empty), or a synthetic fingerprint otherwise.
    @MainActor
    static func previewModel(
        flags: [FrameFlag] = FrameFlag.previewFlags(),
        source: MockFlaggingSource = MockFlaggingSource()
    ) -> (model: FlaggingModel, source: MockFlaggingSource) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-flag-preview-\(UUID().uuidString)", isDirectory: true)
        let store = FlagStore(baseDir: dir)
        for flag in flags { store.add(flag) }

        let model = FlaggingModel(store: store, source: source)
        // Reflect the seeded flags' asset so `currentFlags` resolves.
        if let asset = flags.first?.ref.asset {
            model.setAssetForTesting(asset)
        }
        return (model, source)
    }
}

extension AssetFingerprint {
    /// A stable synthetic fingerprint for previews/tests (no file needed).
    static func preview(filename: String = "preview-clip.mp4") -> AssetFingerprint {
        AssetFingerprint(
            filename: filename,
            byteSize: 1_234_567,
            durationSeconds: 10,
            headHash: "preview"
        )
    }
}

extension FrameFlag {
    /// A handful of flags spread across a 10 s preview clip — enough to
    /// exercise the marker strip and the list.
    static func previewFlags() -> [FrameFlag] {
        let asset = AssetFingerprint.preview()
        func at(_ seconds: Double) -> CMTime {
            CMTime(seconds: seconds, preferredTimescale: 600)
        }
        return [
            FrameFlag(
                ref: FrameRef(asset: asset, pts: at(1.2)),
                detections: [],
                modelID: "yolo26n",
                reason: .wrong,
                note: "false positive on the clipboard"
            ),
            FrameFlag(
                ref: FrameRef(asset: asset, pts: at(4.5)),
                detections: [],
                modelID: "yolo26n",
                reason: .nearMiss
            ),
            FrameFlag(
                ref: FrameRef(asset: asset, pts: at(7.8)),
                detections: [],
                modelID: "yolo26n",
                reason: .other,
                note: "interesting pose"
            ),
        ]
    }
}

#endif
