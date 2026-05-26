@preconcurrency import AVFoundation
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - PlaybackView

/// SwiftUI surface for file-playback rendering.
///
/// Wraps an internal `PlayerView` (a `UIView` / `NSView` whose backing
/// layer *is* the `AVPlayerLayer`) behind a `UIViewRepresentable` /
/// `NSViewRepresentable`. SwiftUI never sees the underlying view or the
/// layer.
///
/// `==` is overridden to use `ObjectIdentifier` on the `PlaybackSource` so
/// SwiftUI doesn't tear down and rebuild the underlying view on every
/// state-change in the parent — source identity is stable for the playback
/// session's lifetime, so equality on identity is safe.
///
/// `videoGravity` is locked to `.resizeAspect` (centered aspect-fit) —
/// [`VideoGeometry`](../Overlay/VideoGeometry.swift)'s `.aspectFit`
/// `displayRect` math assumes this, so the overlay box lands exactly on the
/// on-screen video. The other gravity modes (`.resizeAspectFill`,
/// `.resize`) would silently break that mapping; if a future use case wants
/// fill, pair it with `VideoGeometry`'s `.aspectFill` mode. Tracked in
/// [`plans/features/M3.md`](../../../plans/features/M3.md) §Risks.
///
/// **`onPlayerLayerReady`** fires on MainActor inside `makeUIView` /
/// `makeNSView` and hands the consumer the `AVPlayerLayer` backing the
/// view. Default is a no-op so callers without overlay concerns don't need
/// it. Fires once per representable-create; SwiftUI may recreate the
/// underlying view (e.g. structural identity changes), in which case the
/// closure fires again with the new layer.
///
/// Note: the overlay no longer needs this layer — `DetectionLayer` keys its
/// geometry off `PlaybackController.presentationSize` + a SwiftUI-measured
/// container size via `VideoGeometry`. The callback remains for consumers
/// that want the raw layer for other purposes.
///
/// **Tick driver wiring.** On view-create, `PlaybackView` installs a
/// `DisplayLinkTickDriver` bound to the host view via
/// `PlaybackSource.setTickDriver(_:)`. The Phase 1 default
/// `TaskTickDriver` keeps headless use working; the swap to a
/// screen-synced driver happens at attach time. See
/// [`PlaybackTickDriver.swift`](./PlaybackTickDriver.swift).
public struct PlaybackView: View {

    public let source: PlaybackSource
    private let onPlayerLayerReady: @MainActor (AVPlayerLayer) -> Void

    public init(
        source: PlaybackSource,
        onPlayerLayerReady: @escaping @MainActor (AVPlayerLayer) -> Void = { _ in }
    ) {
        self.source = source
        self.onPlayerLayerReady = onPlayerLayerReady
    }

    public var body: some View {
        PlaybackViewRepresentable(
            source: source,
            onPlayerLayerReady: onPlayerLayerReady
        )
    }
}

// MARK: - Representable (iOS)

#if os(iOS)

/// Internal representable bridging `PlayerView` (UIKit) to SwiftUI.
struct PlaybackViewRepresentable: UIViewRepresentable {
    let source: PlaybackSource
    let onPlayerLayerReady: @MainActor (AVPlayerLayer) -> Void

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.player = source.playerForPreview
        view.playerLayer.videoGravity = .resizeAspect

        // Install the display-link driver bound to this view. Replaces
        // the headless `TaskTickDriver` `PlaybackSource.init` defaults to.
        let driver = DisplayLinkTickDriver(view: view)
        source.setTickDriver(driver)

        onPlayerLayerReady(view.playerLayer)
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        // Keep the layer's player in sync if the source instance has
        // changed (rare — SwiftUI normally tears down and re-creates on
        // identity change because of `==` below, but cover the case).
        if uiView.playerLayer.player !== source.playerForPreview {
            uiView.playerLayer.player = source.playerForPreview
        }
        if uiView.playerLayer.videoGravity != .resizeAspect {
            uiView.playerLayer.videoGravity = .resizeAspect
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        ObjectIdentifier(lhs.source) == ObjectIdentifier(rhs.source)
    }
}

/// `UIView` whose backing layer *is* an `AVPlayerLayer`. The `layerClass`
/// override avoids the sublayer-geometry plumbing that `addSublayer(_:)`
/// would require — the layer fills the view by construction.
///
/// Public only because it's the `UIViewType` exposed by the internal
/// representable (Swift requires the type to be at least as visible as
/// the public-or-internal `makeUIView` return). Not part of the intended
/// consumer surface — apps should always use `PlaybackView`.
public final class PlayerView: UIView {

    public override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    /// Safe cast: `layerClass` override guarantees `layer` is this type.
    public var playerLayer: AVPlayerLayer {
        // swiftlint:disable:next force_cast
        layer as! AVPlayerLayer
    }
}

#elseif os(macOS)

// MARK: - Representable (macOS)

/// Internal representable bridging `PlayerView` (AppKit) to SwiftUI.
struct PlaybackViewRepresentable: NSViewRepresentable {
    let source: PlaybackSource
    let onPlayerLayerReady: @MainActor (AVPlayerLayer) -> Void

    func makeNSView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.player = source.playerForPreview
        view.playerLayer.videoGravity = .resizeAspect

        let driver = DisplayLinkTickDriver(view: view)
        source.setTickDriver(driver)

        onPlayerLayerReady(view.playerLayer)
        return view
    }

    func updateNSView(_ nsView: PlayerView, context: Context) {
        if nsView.playerLayer.player !== source.playerForPreview {
            nsView.playerLayer.player = source.playerForPreview
        }
        if nsView.playerLayer.videoGravity != .resizeAspect {
            nsView.playerLayer.videoGravity = .resizeAspect
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        ObjectIdentifier(lhs.source) == ObjectIdentifier(rhs.source)
    }
}

/// `NSView` whose backing layer *is* an `AVPlayerLayer`. AppKit doesn't
/// have a `layerClass` override — instead, the view is `wantsLayer = true`
/// and `makeBackingLayer()` returns the desired layer subclass. AppKit
/// will then use that layer as `self.layer`.
///
/// Public only because it's the `NSViewType` exposed by the internal
/// representable. Not part of the intended consumer surface — apps should
/// always use `PlaybackView`.
public final class PlayerView: NSView {

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.wantsLayer = true
    }

    public override func makeBackingLayer() -> CALayer {
        AVPlayerLayer()
    }

    /// Safe cast: `makeBackingLayer` returns `AVPlayerLayer`, so the view's
    /// `layer` is guaranteed to be this type after `wantsLayer = true`.
    public var playerLayer: AVPlayerLayer {
        // swiftlint:disable:next force_cast
        layer as! AVPlayerLayer
    }
}

#endif

// MARK: - Preview

/// SwiftUI preview using a bogus URL. AVF tolerates an unloadable URL —
/// the view renders as an empty black surface (the `AVPlayerLayer`'s
/// default background), which is enough to validate layout and that the
/// representable composes correctly under the preview canvas. Live
/// playback previews want the demo app target (M3 Phase 5), where the
/// fixture clip is bundled.
#Preview {
    PlaybackView(
        source: PlaybackSource(url: URL(fileURLWithPath: "/dev/null"))
    )
}
