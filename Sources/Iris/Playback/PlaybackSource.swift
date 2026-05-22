@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import os

// MARK: - Tick driver

/// Drives `PlaybackSource`'s per-tick pixel-buffer pull off
/// `AVPlayerItemVideoOutput`. The production implementation is a
/// `Task.sleep`-based driver running at a nominal display rate; tests inject
/// `ManualTickDriver` to step the source deterministically.
///
/// **Why not `CADisplayLink` / `CVDisplayLink` in Phase 1?** Display links
/// require a host view (or `NSScreen` / `UIScreen`) to attach to, and Phase 1
/// ships `PlaybackSource` without `PlaybackView` (that's Phase 3). The driver
/// abstraction lets Phase 3 swap in a `CADisplayLink`-backed driver vended
/// from the view without changing `PlaybackSource`'s public API. See
/// [`plans/features/M3.md`](../../../plans/features/M3.md) §Phase 1.
public protocol PlaybackTickDriver: Sendable {
    /// Begin emitting ticks. `tick` is invoked on each frame opportunity.
    /// Called once per `PlaybackSource` lifetime, by `start()`. The closure
    /// is `@Sendable` so drivers can dispatch onto any executor they own.
    func start(tick: @escaping @Sendable () -> Void)

    /// Stop emitting ticks. Idempotent. Called by `PlaybackSource.pause()`
    /// and `invalidate()`.
    func stop()
}

/// `Task.sleep`-based driver. Polls at `~hz` Hz from a detached `Task`.
/// Cancellation flows through normally; `stop()` cancels the running task.
public final class TaskTickDriver: PlaybackTickDriver, @unchecked Sendable {
    private let hz: Double
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    public init(hz: Double = 60) {
        self.hz = hz
    }

    public func start(tick: @escaping @Sendable () -> Void) {
        let nanos = UInt64(1_000_000_000.0 / hz)
        let task = Task.detached(priority: .userInitiated) {
            while !Task.isCancelled {
                tick()
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
        lock.lock()
        self.task?.cancel()
        self.task = task
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        let t = self.task
        self.task = nil
        lock.unlock()
        t?.cancel()
    }
}

/// Test-injectable driver. Tests call `fire()` to advance one tick.
public final class ManualTickDriver: PlaybackTickDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var tick: (@Sendable () -> Void)?

    public init() {}

    public func start(tick: @escaping @Sendable () -> Void) {
        lock.lock()
        self.tick = tick
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        self.tick = nil
        lock.unlock()
    }

    /// Emit one tick synchronously.
    public func fire() {
        lock.lock()
        let t = self.tick
        lock.unlock()
        t?()
    }
}

// MARK: - PlaybackSource

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
    private let driver: PlaybackTickDriver
    private let assetID: AssetID
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
        driver.stop()
        continuation.finish()
    }

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
        driver.stop()
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

        driver.start { [weak self] in
            self?.tick()
        }
        player.play()
    }

    /// Pause playback. Stops the tick driver and pauses the player.
    /// Idempotent — returns to `.idle` per the Phase 1 state contract.
    public func pause() async {
        driver.stop()
        player.pause()
        setState(.idle)
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
        driver.stop()
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
