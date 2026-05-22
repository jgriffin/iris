@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import os

// MARK: - PlaybackSource

// The `PlaybackTickDriver` protocol + concrete `TaskTickDriver` /
// `ManualTickDriver` / `DisplayLinkTickDriver` impls live in a sibling
// file: [`PlaybackTickDriver.swift`](./PlaybackTickDriver.swift).

/// File-playback `Source`. Wraps an `AVPlayer` + `AVPlayerItemVideoOutput`,
/// publishing decoded frames to `frames: AsyncStream<Frame>` on each tick of
/// an injectable `PlaybackTickDriver`.
///
/// Per the locked design in
/// [`plans/features/M3.md`](../../../plans/features/M3.md) §Phase 1:
///
/// - `Frame.timestamp` carries **asset time** (`AVPlayerItem.currentTime()`),
///   not host clock. Documented on
///   [`Frame`](../Frame.swift) — the per-source semantics live there.
/// - `AsyncStream` buffering policy is `.bufferingNewest(1)` per
///   [`plans/DECISIONS.md`](../../../plans/DECISIONS.md) §"Runtime frame
///   pipeline".
/// - The stream finishes on EOF (`AVPlayerItem.didPlayToEndTimeNotification`)
///   so a `for await frame in source.frames { … }` loop terminates naturally.
///
/// **Phase 1 scope is intentionally narrow:** `init(url:)`, `start()`,
/// `stop()`, `pause()`, `play()`, `invalidate()`. `seek(to:)` and
/// `step(by:)` land in Phase 2.
///
/// **Invariants justifying `@unchecked Sendable`:**
///   1. All mutable state (`_state`, `eofObservation`) is guarded by `lock`
///      (an `NSLock`).
///   2. `player`, `playerItem`, `videoOutput`, `continuation`, `driver`,
///      `assetID` are immutable after `init`. AVF types are not
///      `Sendable`-clean — the legitimate escape hatch per
///      [`plans/DECISIONS.md`](../../../plans/DECISIONS.md)
///      §"Strict-concurrency escape hatches".
///   3. `AVPlayerItemVideoOutput.copyPixelBuffer(forItemTime:itemTimeForDisplay:)`
///      is documented thread-safe by AVF.
public final class PlaybackSource: Source, @unchecked Sendable {

    // MARK: - Stored state

    private let player: AVPlayer
    private let playerItem: AVPlayerItem
    private let videoOutput: AVPlayerItemVideoOutput
    /// Mutable so `PlaybackView` can swap in a `DisplayLinkTickDriver`
    /// post-init via `setTickDriver(_:)`. Always read/written under
    /// `lock`. Invariant: `driver` is non-nil for the lifetime of the
    /// source.
    private var driver: PlaybackTickDriver
    private let assetID: AssetID
    private let sourceURL: URL
    private let _frames: AsyncStream<Frame>
    private let continuation: AsyncStream<Frame>.Continuation
    private let logger = Logger(subsystem: "iris.playback", category: "source")

    private let lock = NSLock()
    private var _state: SourceState = .idle
    private var eofObservation: NSObjectProtocol?
    private var lastEmittedItemTime: CMTime = .invalid

    // MARK: - Init

    /// Build a `PlaybackSource` for the file at `url`.
    ///
    /// The asset is loaded lazily by `AVPlayerItem`; if the file is missing
    /// or unplayable the failure surfaces via `state` (`.failed`) the first
    /// time `start()` runs the playback pipeline. `init` itself never
    /// throws — matches the deferred-load shape AVF actually uses.
    public convenience init(url: URL) {
        self.init(url: url, driver: TaskTickDriver())
    }

    /// Designated initializer. `driver` is injectable so tests can step the
    /// source deterministically without depending on real-time scheduling.
    public init(url: URL, driver: PlaybackTickDriver) {
        let item = AVPlayerItem(url: url)
        let output = Self.makeVideoOutput()
        item.add(output)

        self.playerItem = item
        self.videoOutput = output
        self.player = AVPlayer(playerItem: item)
        self.driver = driver
        self.assetID = AssetID(raw: url.absoluteString)
        self.sourceURL = url

        let (stream, cont) = AsyncStream.makeStream(
            of: Frame.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        self._frames = stream
        self.continuation = cont
    }

    deinit {
        if let obs = eofObservation {
            NotificationCenter.default.removeObserver(obs)
        }
        currentDriver().stop()
        continuation.finish()
    }

    // MARK: - Driver injection

    /// Swap the tick driver. Used by `PlaybackView` to install a
    /// `DisplayLinkTickDriver` bound to its host view once the view is
    /// attached. The default `TaskTickDriver` injected at `init` time keeps
    /// headless use (no view, e.g. dataset processing) working out of the
    /// box; `PlaybackView` overrides it for screen-synced ticks.
    ///
    /// **Behavior.** If the source is currently `.running`, the new driver
    /// is started and the old driver is stopped atomically — playback
    /// stays uninterrupted across the swap. Otherwise the new driver is
    /// installed but not started; the next `play()` will start it.
    ///
    /// **Idempotency.** Passing the currently-installed driver is a no-op
    /// — checked via `ObjectIdentifier` because `PlaybackTickDriver` is a
    /// class-bound protocol in practice (`Sendable` + reference semantics).
    public func setTickDriver(_ newDriver: PlaybackTickDriver) {
        lock.lock()
        let oldDriver = driver
        let isRunning: Bool = {
            if case .running = _state { return true }
            return false
        }()
        // Identity-equal — nothing to do.
        if ObjectIdentifier(oldDriver as AnyObject) == ObjectIdentifier(newDriver as AnyObject) {
            lock.unlock()
            return
        }
        self.driver = newDriver
        lock.unlock()

        if isRunning {
            newDriver.start { [weak self] in
                self?.tick()
            }
        }
        oldDriver.stop()
    }

    /// Lock-guarded read of the current driver. The driver reference can
    /// change post-init via `setTickDriver(_:)`, so call sites that touch
    /// `driver.start` / `driver.stop` go through this helper rather than
    /// reading the field directly.
    private func currentDriver() -> PlaybackTickDriver {
        lock.lock()
        defer { lock.unlock() }
        return driver
    }

    // MARK: - Preview

    /// The underlying `AVPlayer`. Exposed for `PlaybackView` to attach to
    /// the `AVPlayerLayer` backing its host view — the AVF API takes an
    /// `AVPlayer`, so the view representable needs the reference.
    ///
    /// **Deliberately named for the use case.** This is the documented
    /// escape hatch for the player/layer attach seam (parallels
    /// `AVCapturePreviewSource.connect(to:)` on the capture side). Callers
    /// should not stash this reference for general AVF poking — playback
    /// controls (`play`/`pause`/`seek`/`step`) and state observation go
    /// through `PlaybackSource`'s own API. The legitimate use is exactly
    /// one read at `PlaybackView.makeUIView` / `makeNSView` time.
    public var playerForPreview: AVPlayer { player }

    /// Build the YUV-bi-planar `AVPlayerItemVideoOutput` Iris uses. Uses
    /// the typed `CVPixelBuffer.Attributes` initializer (Swift-only,
    /// `Sendable`-clean — supersedes the deprecated `[String: Any]?`
    /// initializer per the AVF Swift header annotations).
    private static func makeVideoOutput() -> AVPlayerItemVideoOutput {
        var attrs = CVPixelBufferAttributes()
        attrs.pixelFormatType = CVPixelFormatType(
            rawValue: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        )
        // `IOSurfaceProperties: [:]` is populated by the default constructor;
        // an empty dictionary signals "any IOSurface" to AVF, which is what
        // we want for zero-copy IOSurface-backed pixel buffers.
        return AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
    }

    // MARK: - Source

    public var frames: AsyncStream<Frame> { _frames }

    public var state: SourceState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    /// Begin playback and emit frames. Idempotent.
    public func start() async throws {
        try await play()
    }

    /// Stop playback. The frame stream remains alive (a subsequent
    /// `start()` / `play()` resumes); call `invalidate()` to tear down.
    public func stop() async {
        await pause()
    }

    /// Finish the frame stream and release observers. The instance should
    /// not be reused.
    public func invalidate() async {
        currentDriver().stop()
        player.pause()
        clearEofObservation()
        setState(.stopped)
        continuation.finish()
    }

    // MARK: - Playback controls (Phase 1 scope)

    /// Start (or resume) playback. Wires the EOF observer on first call,
    /// starts the tick driver, and calls `player.play()`. Idempotent.
    public func play() async throws {
        let alreadyRunning = enterRunningStateIfNeeded()
        if alreadyRunning { return }

        currentDriver().start { [weak self] in
            self?.tick()
        }
        player.play()
    }

    /// Pause playback. Stops the tick driver and pauses the player.
    /// Idempotent — returns to `.idle` per the Phase 1 state contract.
    public func pause() async {
        currentDriver().stop()
        player.pause()
        setState(.idle)
    }

    // MARK: - Playback controls (Phase 2 scope)

    /// Frame-accurate seek to `target`. `target` is clamped silently to
    /// `[.zero, duration]` — out-of-range input is not an error (per the
    /// Phase 2 locked design in
    /// [`plans/features/M3.md`](../../../plans/features/M3.md) §Phase 2).
    ///
    /// **State invariant:** `seek` does *not* change `SourceState`. A paused
    /// (`.idle`) source stays paused; a `.running` source stays running.
    /// Valid in any non-`.failed` state.
    ///
    /// **Stream invariant:** mid-`play()` `seek` does not finish the
    /// `frames` stream — frame production resumes after the seek completes.
    /// From `.idle`, a single frame at the new position is emitted (one-shot
    /// read, independent of the tick driver).
    public func seek(to target: CMTime) async throws {
        try await ensureReadyToPlay()
        let clamped = clampToAsset(target)

        // AVPlayer.seek is async via a completion handler. Bridge to
        // structured concurrency. `.zero` tolerances give frame-accurate seek.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            player.seek(
                to: clamped,
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { _ in
                cont.resume()
            }
        }

        // Reset the monotonicity guard so the post-seek frame isn't dropped
        // even when seeking backwards. Then yield one frame at the new
        // position — required for the `.idle` (paused-on-load) flow where
        // the tick driver isn't running. For a mid-`play()` seek, this is
        // a harmless extra read; the running driver picks up from there.
        resetMonotonicityGuard()
        await emitOneShotFrame()
    }

    /// Step playback by ±`count` frames. Uses
    /// `AVPlayerItem.step(byCount:)` for ±1-frame accuracy. Stepping past
    /// EOF or before `.zero` is a no-op (AVF clamps internally) — no error,
    /// no crash.
    ///
    /// **State invariant:** `step` does *not* change `SourceState`. A
    /// paused (`.idle`) source stays paused; a `.running` source stays
    /// running. Valid in any non-`.failed` state.
    ///
    /// **Stream invariant:** from `.idle`, the frame at the new position is
    /// emitted via a synchronous one-shot read (independent of the tick
    /// driver). Mid-`play()` `step` does not finish the `frames` stream.
    public func step(by count: Int) async throws {
        try await ensureReadyToPlay()

        // `step(byCount:)` is synchronous on the item; AVF handles the
        // EOF / before-start clamp internally.
        playerItem.step(byCount: count)

        resetMonotonicityGuard()
        await emitOneShotFrame()
    }

    // MARK: - Phase 2 helpers

    /// Wait for `playerItem.status == .readyToPlay`. AVF loads the asset
    /// lazily; `seek` / `step` on an unloaded item are no-ops with garbage
    /// `currentTime`. Short bounded poll — gives up after ~2s, surfacing
    /// the failure via `SourceError.assetLoadFailed(sourceURL)` so callers don't hang on a
    /// broken file. The Phase 1 `start()` path doesn't need this because
    /// `play()` is itself an AVF-driven async unwind; Phase 2's controls
    /// can be invoked *before* `play()` has ever run.
    private func ensureReadyToPlay() async throws {
        // Fast path: already ready.
        if playerItem.status == .readyToPlay { return }

        let deadline = ContinuousClock().now + .seconds(2)
        while ContinuousClock().now < deadline {
            switch playerItem.status {
            case .readyToPlay:
                return
            case .failed:
                setState(.failed(SourceError.assetLoadFailed(sourceURL)))
                throw SourceError.assetLoadFailed(sourceURL)
            case .unknown:
                break
            @unknown default:
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
        }
        // Timed out — surface as not-ready.
        setState(.failed(SourceError.assetLoadFailed(sourceURL)))
        throw SourceError.assetLoadFailed(sourceURL)
    }

    /// Clamp `target` to `[.zero, duration]`. If duration is unknown
    /// (`.indefinite` / `.invalid`) we fall through to `target` rather than
    /// clamping against garbage — the asset-load gate in
    /// `ensureReadyToPlay()` is supposed to prevent that.
    private func clampToAsset(_ target: CMTime) -> CMTime {
        let duration = playerItem.duration
        let lower: CMTime = (CMTimeCompare(target, .zero) < 0) ? .zero : target
        guard duration.isValid, !duration.isIndefinite else { return lower }
        if CMTimeCompare(lower, duration) > 0 { return duration }
        return lower
    }

    /// Reset `lastEmittedItemTime` so the monotonicity guard in `tick()`
    /// doesn't drop a post-seek frame whose time is ≤ the previously
    /// emitted time (e.g. a seek backwards).
    private func resetMonotonicityGuard() {
        lock.lock()
        lastEmittedItemTime = .invalid
        lock.unlock()
    }

    /// Synchronously emit one frame at the player's current item time.
    /// Tolerates a brief decoder warm-up after seek/step by polling
    /// `hasNewPixelBuffer(forItemTime:)` for a short bounded window.
    /// Returns without emitting if no buffer materializes — covers the
    /// "step backwards at zero" and "step past EOF" no-op cases.
    private func emitOneShotFrame() async {
        let deadline = ContinuousClock().now + .milliseconds(500)
        while ContinuousClock().now < deadline {
            let itemTime = playerItem.currentTime()
            if itemTime.isValid, !itemTime.isIndefinite,
                videoOutput.hasNewPixelBuffer(forItemTime: itemTime)
            {
                tick()
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)  // 5ms
        }
        // No buffer arrived — graceful no-op (e.g. step(-1) at .zero,
        // step past EOF).
    }

    // MARK: - Tick

    /// One frame opportunity. Called by the driver on each tick.
    ///
    /// Reads the current player-item time, asks the video output whether a
    /// pixel buffer is ready for that time, and — if so — yields a `Frame`
    /// stamped with the item time. Suppresses duplicate emissions when the
    /// player hasn't advanced (e.g. paused-on-load, scrub-without-step).
    private func tick() {
        let itemTime = playerItem.currentTime()
        guard itemTime.isValid, !itemTime.isIndefinite else { return }

        guard videoOutput.hasNewPixelBuffer(forItemTime: itemTime) else { return }

        var displayTime = CMTime()
        guard
            let pixelBuffer = videoOutput.copyPixelBuffer(
                forItemTime: itemTime,
                itemTimeForDisplay: &displayTime
            )
        else { return }

        lock.lock()
        // Drop frames that haven't advanced past the last emission. This
        // covers the paused-on-load case and the post-EOF-quiescent case
        // where the item clock stops but the driver keeps ticking.
        if lastEmittedItemTime.isValid,
            CMTimeCompare(itemTime, lastEmittedItemTime) <= 0
        {
            lock.unlock()
            return
        }
        lastEmittedItemTime = itemTime
        lock.unlock()

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        let frame = Frame(
            pixelBuffer: pixelBuffer,
            timestamp: itemTime,
            orientation: .up,
            source: .playback(assetID),
            format: .yuv420BiPlanarFull,
            dimensions: CGSize(width: width, height: height)
        )
        continuation.yield(frame)
    }

    // MARK: - End of item

    // MARK: - Test hooks

    /// Internal-only handles for `@testable import Iris` consumers. Lets
    /// tests reach the underlying `AVPlayer` / `AVPlayerItem` to set
    /// `rate`, poll `status`, and otherwise prime AVF state without
    /// adding those concerns to the public API. Not for use by Iris
    /// consumers — the public surface is `start()` / `play()` / `pause()`.
    internal struct TestHooks {
        internal let player: AVPlayer
        internal let playerItem: AVPlayerItem
    }

    internal var testHooks: TestHooks {
        TestHooks(player: player, playerItem: playerItem)
    }

    private func handleEndOfItem() {
        currentDriver().stop()
        clearEofObservation()
        setState(.stopped)
        continuation.finish()
    }

    // MARK: - Sync state helpers (safe from async contexts via NSLock)

    /// Set `_state` under `lock`. Synchronous so async callers can invoke
    /// it without tripping Swift 6's `NSLock`-from-async ban.
    private func setState(_ newValue: SourceState) {
        lock.lock()
        _state = newValue
        lock.unlock()
    }

    /// Idempotency check + EOF-observer wiring under `lock`. Returns
    /// `true` if the source was already `.running` (caller should bail).
    private func enterRunningStateIfNeeded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .running = _state { return true }
        if eofObservation == nil {
            eofObservation = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification,
                object: playerItem,
                queue: nil
            ) { [weak self] _ in
                self?.handleEndOfItem()
            }
        }
        _state = .running
        return false
    }

    private func clearEofObservation() {
        lock.lock()
        let obs = eofObservation
        eofObservation = nil
        lock.unlock()
        if let obs { NotificationCenter.default.removeObserver(obs) }
    }
}
