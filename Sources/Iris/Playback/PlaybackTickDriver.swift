import Foundation
import QuartzCore

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Protocol

/// Drives `PlaybackSource`'s per-tick pixel-buffer pull off
/// `AVPlayerItemVideoOutput`. The headless default is `TaskTickDriver`
/// (`Task.sleep` at a nominal display rate); `PlaybackView` swaps in a
/// `DisplayLinkTickDriver` bound to its host view once it's attached;
/// tests inject `ManualTickDriver` to step the source deterministically.
///
/// The driver abstraction is the seam between `PlaybackSource` (Phase 1
/// scope: pure-headless playback pipeline) and the platform-specific
/// `CADisplayLink` / `NSView.displayLink` mechanisms that need a host view
/// (Phase 3 scope: `PlaybackView`). See
/// [`plans/features/M3.md`](../../../plans/features/M3.md) §Phase 1 + §Phase 3.
public protocol PlaybackTickDriver: Sendable {
    /// Begin emitting ticks. `tick` is invoked on each frame opportunity.
    /// The closure is `@Sendable` so drivers can dispatch onto any executor
    /// they own.
    func start(tick: @escaping @Sendable () -> Void)

    /// Stop emitting ticks. Idempotent.
    func stop()
}

// MARK: - TaskTickDriver

/// `Task.sleep`-based driver. Polls at `~hz` Hz from a detached `Task`.
/// Cancellation flows through normally; `stop()` cancels the running task.
///
/// **When this is the right driver.** Headless use of `PlaybackSource`
/// (no view attached) — e.g. dataset processing, model-eval pipelines,
/// detector benchmark runs. `PlaybackView` swaps this out for a real
/// display-link driver once a host view exists.
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

// MARK: - ManualTickDriver

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

// MARK: - DisplayLinkTickDriver

/// Display-link-backed driver bound to a host view. The view vends a
/// `CADisplayLink` via `UIView.displayLink(target:selector:)` (iOS 15+) or
/// `NSView.displayLink(target:selector:)` (macOS 14+); both shapes return
/// a `CADisplayLink` whose tick rate is bounded by the screen's refresh
/// rate. The display link itself doesn't drive playback rate (AVF does);
/// it just provides a screen-synced cadence for polling `copyPixelBuffer`.
///
/// **Why a host view, not `CADisplayLink(target:selector:)` directly.**
/// `UIScreen.main` is deprecated in iOS 16+; the recommended path is to
/// vend the display link from the view that's actually being rendered.
/// This also matters for multi-display setups on macOS — the link picks
/// up the screen the view is attached to and adjusts its preferred frame
/// rate accordingly.
///
/// **Lifecycle.** `start(tick:)` retains the tick closure and attaches the
/// display link to the main run loop in `.common` mode (so it keeps firing
/// during scroll-tracking on iOS). `stop()` invalidates the display link;
/// after `stop`, `start` may be called again to re-attach. The driver
/// retains a weak reference to the host view; if the view is deallocated,
/// the display link is implicitly cleaned up.
///
/// **`@unchecked Sendable`.** The internal state (`displayLink`, `tick`)
/// is guarded by `NSLock`; `CADisplayLink` itself is not `Sendable`-clean
/// but is only touched from the main run loop after attach. Cross-actor
/// uses (`start`/`stop` from `PlaybackSource`) cross the lock.
final class DisplayLinkTickDriver: NSObject, PlaybackTickDriver, @unchecked Sendable {

    private let lock = NSLock()
    private var displayLink: CADisplayLink?
    private var tick: (@Sendable () -> Void)?

    #if os(iOS)
    private weak var view: UIView?

    init(view: UIView) {
        self.view = view
        super.init()
    }
    #elseif os(macOS)
    private weak var view: NSView?

    init(view: NSView) {
        self.view = view
        super.init()
    }
    #endif

    func start(tick: @escaping @Sendable () -> Void) {
        lock.lock()
        self.tick = tick
        let existing = self.displayLink
        lock.unlock()

        // Display-link creation must happen on the main actor — the
        // `UIView.displayLink` / `NSView.displayLink` APIs touch view
        // state and must be called from the main thread.
        existing?.invalidate()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.attachDisplayLink()
        }
    }

    func stop() {
        lock.lock()
        let link = self.displayLink
        self.displayLink = nil
        self.tick = nil
        lock.unlock()
        // Invalidate on whichever thread we're on; `CADisplayLink.invalidate`
        // is documented thread-safe.
        link?.invalidate()
    }

    @MainActor private func attachDisplayLink() {
        guard let view else { return }

        #if os(iOS)
        // iOS: the display link is vended from a `UIScreen`. Prefer the
        // view's window's screen so the link picks the right refresh rate
        // on multi-display iPads; fall back to a `CADisplayLink(target:
        // selector:)` if the view isn't in a window yet (rare — SwiftUI
        // attaches it before `makeUIView` returns the host view to the
        // hierarchy, but the layout pass that adds the view to a window
        // happens later). Retry on next runloop tick if needed.
        let screen = view.window?.screen ?? UIScreen.main
        guard
            let link = screen.displayLink(withTarget: self, selector: #selector(displayLinkFired))
        else {
            // No display link available (e.g. headless test bench). Tick
            // driver stays inert; tests using `PlaybackView` headlessly
            // can fall back to the `TaskTickDriver` default.
            return
        }
        #elseif os(macOS)
        // macOS 14+: `NSView.displayLink(target:selector:)` returns a
        // non-optional `CADisplayLink` bound to the view's screen. The
        // view must be in a window for this to pick the right screen;
        // AppKit handles unattached views by lazily binding when the
        // window arrives.
        let link = view.displayLink(target: self, selector: #selector(displayLinkFired))
        #endif

        // Preferred range: bounded by the screen but biased to the typical
        // 30 fps asset rate. AVF drives the playback clock; the display
        // link only paces our `copyPixelBuffer` polling.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 120, preferred: 60)
        link.add(to: RunLoop.main, forMode: RunLoop.Mode.common)

        lock.lock()
        self.displayLink = link
        lock.unlock()
    }

    @objc private func displayLinkFired() {
        lock.lock()
        let t = self.tick
        lock.unlock()
        t?()
    }
}
