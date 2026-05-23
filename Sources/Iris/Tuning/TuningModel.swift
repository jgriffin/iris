import Foundation
import Observation
import SwiftUI
import os

// MARK: - TuningRouter

/// Non-generic facade onto a `TuningModel<Settings>`. The
/// `DetectorPipeline` consults this surface — it can't see the
/// concrete `Settings` parameter, but it doesn't need to: it only
/// needs the current detector reference (post-hot-swap) and the
/// optional output-stage filter.
///
/// **Why a protocol seam.** `TuningModel` is generic over `Settings:
/// DetectorSettings` so binding from SwiftUI stays type-safe at the
/// concrete-settings call site. The pipeline can't be generic on the
/// same axis without rippling the parameter through every existing
/// `DetectorPipeline(in:cache:)` call site. `any TuningRouter` is the
/// minimum erasure that keeps the pipeline source-stable.
///
/// **Concurrency.** `@MainActor` — the only conformer is
/// `TuningModel`, which is `@MainActor @Observable` per the M3
/// `PlaybackController` precedent. Pipeline reads happen from
/// non-MainActor contexts (detection runs off the main actor); the
/// pipeline therefore `await`s `MainActor.run { … }` to read the
/// router properties. The properties are non-async on the protocol
/// because the actor hop happens at the call site, not inside the
/// getter.
@MainActor
public protocol TuningRouter: AnyObject, Sendable {

    /// The current detector instance. May be `nil` when no detector is
    /// owned by the router (e.g. a tuning model wired in for filter
    /// passes only). `DetectorPipeline` uses this when present to pick
    /// up post-hot-swap detector instances; falls back to its own
    /// `detectors` array when this returns `nil`.
    var currentDetector: (any Detector)? { get }

    /// Optional filter predicate applied to the *output* of both cache
    /// lookups and fresh inferences before the pipeline returns. `nil`
    /// disables the pass entirely.
    ///
    /// **Why output-stage, not write-time.** Keeping the cache as a
    /// record of what the detector actually produced (not what passed
    /// the filter) means filter-tier knob changes can be re-applied
    /// without re-running inference. The cache stays the model's
    /// ground truth; the filter is a re-renderable view onto it.
    var filter: (@Sendable (Detection) -> Bool)? { get }
}

// MARK: - TuningModel

/// `@MainActor @Observable` wrapper over a concrete `Settings` value
/// and (optionally) the `TunableDetector` that consumes it.
///
/// **Responsibilities.**
///
///   1. Hold the live `settings` snapshot. SwiftUI binds to this and
///      mutates it via `update(_:to:)` (or — for filter installation —
///      assigns to `filter` directly).
///   2. Translate every property write into a `SettingChange`, route
///      it through `detector?.apply(_:)`, and consume the
///      `ApplyResult` per tier:
///        - `.view`  — no-op at the model. The consuming SwiftUI
///                     `View` re-renders because it observes
///                     `settings` directly.
///        - `.filter` — settings already mutated; the pipeline picks
///                     up the new value via the next `filter`
///                     closure read (if the consumer installs one
///                     keyed off `settings`).
///        - `.detector(rebuilt:)` — swap `currentDetector` to the
///                     rebuilt instance and call
///                     `cache?.invalidateAll()`. Simplest correct
///                     shape per the M4 brief; the conditional Phase
///                     4 upgrade is per-entry fingerprinting.
///   3. Expose `currentDetector` so `DetectorPipeline` can pick up
///      the post-hot-swap instance without the consumer having to
///      thread it manually.
///
/// **Why the apply-result routing lives here (not in the pipeline).**
/// The pipeline runs detectors against frames; it shouldn't know
/// about settings types. The model owns the settings-to-effect
/// channel; the pipeline only reads the side-effects (current
/// detector + filter slot). Mirrors the M3 `PlaybackController`
/// shape: a SwiftUI-shaped observable that fronts a non-MainActor
/// pipeline component without leaking the underlying threading
/// model.
///
/// **Concurrency.** `@MainActor` per the M3 precedent. SwiftUI binds
/// directly to `settings` and `filter`; pipeline reads happen via the
/// `TuningRouter` protocol, with the actor hop landing at the
/// pipeline call site.
///
/// **No persistence in Phase 2.** Settings live in memory only. The
/// M4 brief defers persistence to the consumer (matches the M3
/// doctrine of UI-shaped state outside the package); see
/// `plans/QUESTIONS.md`'s "settings persistence" open question.
@MainActor
@Observable
public final class TuningModel<Detector: TunableDetector>: TuningRouter {

    // MARK: - Observable state

    /// Live settings snapshot. SwiftUI views bind to this directly;
    /// writes flow through `update(_:to:)` so the apply-result
    /// classifier runs on every transition.
    public private(set) var settings: Detector.Settings

    /// The most-recent change emitted by `update(_:to:)`. Exposed for
    /// observation-driven UIs (and tests) that want to inspect the
    /// last transition without subscribing to a separate stream.
    /// `@Observable` re-publishes any mutation; consumers binding here
    /// see one tick per `update(_:to:)` call.
    public private(set) var lastChange: SettingChange?

    /// The tier verdict from the most-recent `update(_:to:)`. Tests
    /// assert against this; UIs can use it to surface "we just
    /// rebuilt the detector" affordances. `nil` until the first
    /// `update(_:to:)` call.
    public private(set) var lastApplyTier: ChangeTier?

    /// Current detector instance. `update(_:to:)` swaps this on
    /// `.detector` tier with the freshly-built detector from
    /// `ApplyResult.detector(rebuilt:)`; otherwise it stays the same
    /// reference (the detector reads from its `settings` snapshot,
    /// which is locked at construction time, so `.filter` / `.view`
    /// tiers don't change the detector at all — the *next* rebuild
    /// is the one that picks up accumulated `.filter`-tier mutations
    /// inside the model's `settings` value).
    public private(set) var detector: Detector?

    /// `TuningRouter` conformance. Type-erases `detector` to the
    /// non-generic `any Detector` so pipelines can read it without
    /// the `TunableDetector` associatedtype rippling through.
    public var currentDetector: (any Iris.Detector)? { detector }

    /// Optional output-stage filter. The pipeline applies this to
    /// both cache lookups and fresh inferences before returning. UIs
    /// install / clear this directly; the M4 channel doesn't derive
    /// it automatically (concrete settings-to-filter projections are
    /// detector-specific and land alongside each detector's tuning
    /// view in Phase 3 or later).
    public var filter: (@Sendable (Detection) -> Bool)?

    /// Optional callback invoked *after* `cache?.invalidateAll()` on a
    /// `.detector`-tier transition (and after the detector reference
    /// swap, if any).
    ///
    /// **Why this hook exists.** Detector-tier changes invalidate the
    /// playback cache so the next inference produces fresh entries
    /// under the new settings. When the source is *playing*, frames
    /// flow naturally and the new detector picks up on the next
    /// arrival. When the source is *paused*, no frames flow — the
    /// cache is empty, the overlay reads nil, nothing draws, and the
    /// user has no way to recover without un-pausing.
    ///
    /// Consumers wire this to a one-shot re-emit on their frame
    /// source (e.g. `PlaybackSource.emitOneShotFrame()` via
    /// `seek(to: source.currentTime)`) so the pipeline gets a frame
    /// to re-run against. The callback fires on `MainActor` since
    /// frame-source state is typically `@MainActor`-isolated.
    ///
    /// Fires **only** on `.detector` tiers — not on `.view` or
    /// `.filter`. View/filter tiers don't invalidate the cache and
    /// don't require a fresh inference; their effects show through
    /// either via SwiftUI observation (`.view`) or via the
    /// `DetectionLayer.tuning` / pipeline filter pass (`.filter`).
    public var onDetectorTierChange: (@Sendable @MainActor () -> Void)?

    // MARK: - Stored

    /// Cache invalidation hook. `update(_:to:)` calls
    /// `cache?.invalidateAll()` on `.detector`-tier transitions.
    /// `nil` is valid — capture-only consumers without a playback
    /// cache pass `nil` and the detector-tier swap still works
    /// (there's just nothing to invalidate).
    private let cache: (any DetectionCache)?

    private let logger = Logger(subsystem: "iris.tuning", category: "model")

    // MARK: - Init

    /// Build a model wired to the supplied detector + cache. The
    /// detector's current `settings` is the starting snapshot — the
    /// model is a window onto whatever the detector was constructed
    /// with.
    public init(detector: Detector, cache: (any DetectionCache)? = nil) {
        self.detector = detector
        self.settings = detector.settings
        self.cache = cache
    }

    /// Detector-less init. Useful when the consumer wants to observe
    /// settings + drive a filter pass without owning the detector
    /// reference (e.g. an explicit `currentDetector: nil` router that
    /// only carries the filter slot). `update(_:to:)` becomes a
    /// settings-mutation-only call in this shape — there's no
    /// classifier to route through.
    public init(settings: Detector.Settings, cache: (any DetectionCache)? = nil) {
        self.detector = nil
        self.settings = settings
        self.cache = cache
    }

    // MARK: - Mutation

    /// Primary write surface. Mutates `settings` via the supplied
    /// keyPath, builds a `SettingChange`, routes it through
    /// `detector?.apply(_:)`, and consumes the result per tier.
    ///
    /// **No-op short-circuit.** If `newValue` equals the existing
    /// value, the call is a no-op — no change emitted, no apply
    /// routed, no observation tick. Matches the classifier's `.view`
    /// short-circuit on identical old/new values.
    public func update<T: Equatable>(
        _ keyPath: WritableKeyPath<Detector.Settings, T>,
        to newValue: T
    ) {
        let oldValue = settings[keyPath: keyPath]
        guard oldValue != newValue else { return }

        settings[keyPath: keyPath] = newValue

        let key = changeKey(for: keyPath, on: settings)
        guard
            let change = buildChange(
                key: key,
                oldValue: oldValue,
                newValue: newValue
            )
        else {
            // Type we don't know how to encode into `SettingChange.Value`.
            // Settings is already mutated; no classifier dispatch.
            logger.warning(
                "update: no SettingChange.Value variant for keyPath \(key, privacy: .public); settings mutated, classifier skipped"
            )
            lastChange = nil
            lastApplyTier = nil
            return
        }

        lastChange = change

        guard let detector else {
            lastApplyTier = nil
            return
        }

        let result = detector.apply(change)
        lastApplyTier = result.tier

        switch result {
        case .view, .filter:
            // Detector unchanged; cache unchanged. The settings write
            // already happened; SwiftUI views observing `settings`
            // (or the filter closure derived from it) tick on the
            // `@Observable` edge.
            return

        case .detector(let rebuilt):
            // Hot-swap doctrine (2026-05-20). `rebuilt` is the fresh
            // detector instance with the new settings baked in. If
            // the conformer didn't supply one (Phase 1 placeholder
            // path, or a misconfigured conformer), we leave the
            // current detector in place — the cache invalidation
            // still runs, so the next inference produces fresh
            // entries; the *settings*-as-source-of-truth shape
            // means the detector's `settings.minimumConfidence`
            // computed forward isn't picked up until rebuild, but
            // safer than ignoring the tier verdict entirely.
            if let rebuilt = rebuilt as? Detector {
                self.detector = rebuilt
            } else if rebuilt != nil {
                logger.error(
                    "update: rebuilt detector type mismatch (expected \(String(describing: Detector.self), privacy: .public)); keeping current instance"
                )
            }
            if let cache {
                // Cache invalidation + pause-emit hook fire in the same
                // Task so the hook always runs *after* the cache is
                // cleared (the hook's typical wiring is a frame re-emit;
                // an out-of-order race would re-emit *before* the cache
                // was empty, producing a hit on the stale entry instead
                // of a fresh inference under the new detector).
                let hook = onDetectorTierChange
                Task { @MainActor in
                    await cache.invalidateAll()
                    hook?()
                }
            } else {
                // No cache → no invalidation to order against. Still
                // surface the tier transition so consumers that wire a
                // pause-emit even in cache-less configurations (capture-
                // only setups using `TuningModel` for hot-swap) get the
                // callback.
                let hook = onDetectorTierChange
                Task { @MainActor in
                    hook?()
                }
            }
        }
    }

    // MARK: - SwiftUI bindings

    /// SwiftUI binding factory that routes mutations through
    /// `update(_:to:)` instead of mutating `settings` directly.
    ///
    /// **Why a helper, not a direct `Bindable`-style projection.** SwiftUI's
    /// `$model.settings.minimumConfidence` would write to the property
    /// in place, *bypassing* the tier classifier — which means a
    /// `.detector`-tier change would silently leave the cache stale.
    /// Forcing writes through `update(_:to:)` keeps the tier verdict +
    /// cache invalidation on every transition.
    ///
    /// **Concurrency.** `@MainActor`-isolated like the rest of the
    /// model; `Binding` getter/setter are read on the main runloop by
    /// SwiftUI, so the actor hop is implicit. The returned binding
    /// captures `self` weakly is *not* required here: `TuningModel`
    /// outlives every view that binds to it (the views are owned by
    /// the SwiftUI tree, the model is owned by the demo / consumer
    /// scope), and the binding's strong capture is the same shape
    /// `@Bindable` uses on `@Observable` references.
    public func binding<T: Sendable & Equatable>(
        _ keyPath: WritableKeyPath<Detector.Settings, T>
    ) -> Binding<T> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { newValue in self.update(keyPath, to: newValue) }
        )
    }

    // MARK: - Private helpers

    /// Map a `WritableKeyPath<Settings, T>` to its schema `key` via
    /// the settings type's hand-rolled `key(for:)` bridge. Returns
    /// `""` when the keyPath isn't in the bridge — the classifier
    /// then routes through the worst-case `.detector` fallback,
    /// which is correct but expensive (cache invalidated; rebuild
    /// runs). See `DetectorSettings.key(for:)` for why this isn't
    /// derived from `_kvcKeyPathString`.
    private func changeKey<T>(
        for keyPath: WritableKeyPath<Detector.Settings, T>,
        on _: Detector.Settings
    ) -> String {
        Detector.Settings.key(for: keyPath) ?? ""
    }

    /// Build a `SettingChange.Value` payload from a typed value. One
    /// branch per known `SettingKind` variant. Returns `nil` for
    /// types outside the supported set (a hook for the
    /// `SettingKind.string` variant once Phase 1's TODO lands).
    private func buildChange<T: Equatable>(
        key: String,
        oldValue: T,
        newValue: T
    ) -> SettingChange? {
        if let old = oldValue as? Float, let new = newValue as? Float {
            return SettingChange.float(key: key, from: old, to: new)
        }
        if let old = oldValue as? Int, let new = newValue as? Int {
            return SettingChange.int(key: key, from: old, to: new)
        }
        if let old = oldValue as? Bool, let new = newValue as? Bool {
            return SettingChange.toggle(key: key, from: old, to: new)
        }
        if let old = oldValue as? Set<String>, let new = newValue as? Set<String> {
            return SettingChange.multiSelect(key: key, from: old, to: new)
        }
        return nil
    }
}
