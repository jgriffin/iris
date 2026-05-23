import CoreGraphics
import Vision

/// `Detector` conformer wrapping Apple's Vision rectangle-detection request.
///
/// Detects rectangular shapes in a frame (e.g., paper, screens, signs, ID
/// cards) and reports each one as a `Detection` with a normalized bounding
/// box plus the four corner `Keypoint`s of the detected quadrilateral.
///
/// **API choice.** Uses the value-type Swift Vision API
/// (`DetectRectanglesRequest` / `RectangleObservation`) introduced for
/// iOS 18 / macOS 15 — Iris's iOS 26 / macOS 26 floor is well within
/// support. The newer struct-based API is preferred over the classic
/// `VNDetectRectanglesRequest` because:
///
///   1. `DetectRectanglesRequest` is a `Sendable` `struct` and
///      `RectangleObservation` (via `VisionObservation: Sendable`) is too,
///      so the entire pipeline crosses actor boundaries without
///      `@preconcurrency` or `@unchecked` escape hatches.
///   2. `perform(on: pixelBuffer, orientation:)` is natively `async throws`,
///      so the adapter is a straight `await` — no `withCheckedThrowingContinuation`
///      bridge to a completion handler.
///   3. Tunable properties (`minimumAspectRatio`, `quadratureToleranceDegrees`,
///      …) are plain `var Float`s on the request struct rather than
///      Obj-C properties on an `NSObject` subclass.
///
/// **Concurrency.** Stateless `struct` — `Sendable` falls out for free, per
/// the locked `Detector` shape in `plans/DECISIONS.md`. A fresh request is
/// constructed inside `detect(in:)` so the detector itself holds no mutable
/// state across calls.
///
/// **Tuning (M4).** Conforms to `TunableDetector` with
/// `Settings = VisionRectanglesSettings`. The `settings` value is the
/// source of truth for every Vision knob; the individual `let` properties
/// below forward to `settings` for source-level backwards compatibility
/// with pre-M4 call sites. `apply(_:)` is the per-knob × direction
/// classifier — see the implementation for the verdict table.
public struct VisionRectanglesDetector: TunableDetector {

    // MARK: - Settings

    /// Source-of-truth tunable knob values. Mutating happens *outside*
    /// the detector (the hot-swap doctrine — construct a fresh
    /// instance with new settings); the property is read-only here.
    public let settings: VisionRectanglesSettings

    // MARK: - Backwards-compatible knob accessors

    /// Minimum aspect ratio (short-side / long-side) for accepted
    /// rectangles. Mirrors `DetectRectanglesRequest.minimumAspectRatio`.
    /// Defaults to `0.5` (Vision's own default for revision 1).
    public var minimumAspectRatio: Float { settings.minimumAspectRatio }

    /// Maximum aspect ratio for accepted rectangles. Mirrors
    /// `DetectRectanglesRequest.maximumAspectRatio`. Defaults to `0.5` —
    /// matching Vision's default, which is the *minimum* allowed value.
    /// Set higher (e.g. `1.0`) to accept squares; the Vision default of
    /// `0.5` is intentionally narrow.
    public var maximumAspectRatio: Float { settings.maximumAspectRatio }

    /// Smallest accepted rectangle as a fraction of the shortest image
    /// dimension. Mirrors `DetectRectanglesRequest.minimumSize`. Defaults
    /// to Vision's own default of `0.2`.
    public var minimumSize: Float { settings.minimumSize }

    /// Maximum number of rectangles to return. `0` means unlimited; mirrors
    /// Vision's default.
    public var maximumObservations: Int { settings.maximumObservations }

    /// How far each corner is allowed to deviate from 90° (in degrees).
    /// Mirrors `DetectRectanglesRequest.quadratureToleranceDegrees`.
    /// Defaults to Vision's own default of `30.0`.
    public var quadratureToleranceDegrees: Float { settings.quadratureToleranceDegrees }

    /// Minimum confidence for a rectangle to be returned. Mirrors
    /// `DetectRectanglesRequest.minimumConfidence`. Defaults to `0.0` so the
    /// adapter is permissive by default; callers tune via init.
    public var minimumConfidence: Float { settings.minimumConfidence }

    /// Label applied to every emitted `Detection`. Public so callers can
    /// override (e.g. `"document"` for a doc-scanner use case) without
    /// re-wrapping the detector.
    public var label: String { settings.label }

    public let availability: DetectorAvailability = .available

    public let modelIdentifier: String = "vision.rectangles"

    // MARK: - Init

    /// Settings-shaped init. The hot-swap doctrine builds fresh
    /// instances this way after a detector-tier change.
    public init(settings: VisionRectanglesSettings) {
        self.settings = settings
    }

    /// Backwards-compatible convenience init that builds a
    /// `VisionRectanglesSettings` from raw arguments. Existing call
    /// sites (and tests) continue to work unchanged.
    public init(
        minimumAspectRatio: Float = 0.5,
        maximumAspectRatio: Float = 0.5,
        minimumSize: Float = 0.2,
        maximumObservations: Int = 0,
        quadratureToleranceDegrees: Float = 30.0,
        minimumConfidence: Float = 0.0,
        label: String = "rectangle"
    ) {
        self.init(
            settings: VisionRectanglesSettings(
                minimumAspectRatio: minimumAspectRatio,
                maximumAspectRatio: maximumAspectRatio,
                minimumSize: minimumSize,
                maximumObservations: maximumObservations,
                quadratureToleranceDegrees: quadratureToleranceDegrees,
                minimumConfidence: minimumConfidence,
                label: label
            )
        )
    }

    // MARK: - Detector

    /// No-op. Vision's built-in requests don't expose an explicit prewarm
    /// hook, and running a throwaway request against a synthetic pixel
    /// buffer here would just shift the first-frame cost rather than
    /// remove it. Callers that care about first-frame latency should run
    /// `detect(in:)` against a representative frame at warm-up time.
    public func prewarm() async {
        // intentionally empty
    }

    public func detect(in frame: Frame) async throws -> [Detection] {
        var request = DetectRectanglesRequest()
        request.minimumAspectRatio = settings.minimumAspectRatio
        request.maximumAspectRatio = settings.maximumAspectRatio
        request.minimumSize = settings.minimumSize
        request.maximumObservations = settings.maximumObservations
        request.quadratureToleranceDegrees = settings.quadratureToleranceDegrees
        request.minimumConfidence = settings.minimumConfidence

        let observations = try await request.perform(
            on: frame.pixelBuffer,
            orientation: frame.orientation
        )

        return observations.map { observation in
            // `boundingBox` on RectangleObservation is the axis-aligned
            // hull of the four corners in Vision-native normalized
            // (bottom-left origin) coordinates. We preserve that
            // convention here — the centralized Y-flip lives in
            // `NormalizedGeometryConverting` (Phase 4), not at the
            // adapter boundary.
            let bbox = observation.boundingBox.cgRect

            // Keypoint order: topLeft, topRight, bottomRight, bottomLeft.
            // Documented invariant — downstream code that consumes corners
            // for an oriented quad (e.g., perspective-correct overlay) can
            // rely on this ordering.
            let keypoints: [Detection.Keypoint] = [
                Detection.Keypoint(
                    name: "topLeft",
                    position: observation.topLeft.cgPoint,
                    confidence: observation.confidence
                ),
                Detection.Keypoint(
                    name: "topRight",
                    position: observation.topRight.cgPoint,
                    confidence: observation.confidence
                ),
                Detection.Keypoint(
                    name: "bottomRight",
                    position: observation.bottomRight.cgPoint,
                    confidence: observation.confidence
                ),
                Detection.Keypoint(
                    name: "bottomLeft",
                    position: observation.bottomLeft.cgPoint,
                    confidence: observation.confidence
                ),
            ]

            return Detection(
                boundingBox: bbox,
                label: settings.label,
                confidence: observation.confidence,
                keypoints: keypoints,
                sourceModelID: modelIdentifier
            )
        }
    }

    // MARK: - TunableDetector

    /// Per-knob × direction tier classifier.
    ///
    /// Verdict table (Vision uses every knob below as a *model
    /// parameter* — the request is built fresh per call from
    /// `settings`, so widening any acceptance window means the model
    /// would emit shapes it previously suppressed; the cache can't
    /// recover those without re-inference):
    ///
    ///   | Knob                          | Raise        | Lower        |
    ///   | ----------------------------- | ------------ | ------------ |
    ///   | `minimumConfidence`           | `.filter`    | `.detector`  |
    ///   | `minimumAspectRatio`          | `.filter`    | `.detector`  |
    ///   | `maximumAspectRatio`          | `.detector`  | `.filter`    |
    ///   | `minimumSize`                 | `.filter`    | `.detector`  |
    ///   | `quadratureToleranceDegrees`  | `.detector`  | `.filter`    |
    ///   | `maximumObservations`         | (see below)  | (see below)  |
    ///   | `label`                       | `.filter` (always — relabel pass) |
    ///
    /// `maximumObservations`: `0` means *unlimited*. Anything → `0`,
    /// and `finite → larger finite`, both surface observations the
    /// model previously truncated → `.detector`. `0 → finite` and
    /// `finite → smaller finite` trim the existing list → `.filter`.
    /// No-op transitions resolve to `.view` (nothing to do).
    public func apply(_ change: SettingChange) -> ApplyResult {
        // No-op short-circuit: identical old/new value is `.view`
        // (the model is unchanged and the existing cache is exactly
        // what we want to keep showing). Useful for UIs that emit a
        // change on every gesture frame without de-duping.
        if change.oldValue == change.newValue {
            return .view
        }

        // Compute the post-change settings snapshot once. Every
        // `.detector` arm below builds a fresh detector from this
        // value (M4 Phase 2 wiring: hot-swap by reference per the
        // 2026-05-20 doctrine). `.filter` / `.view` arms still
        // benefit from the centralized projection — the caller's
        // `TuningModel` has already mutated its own settings copy;
        // this local is the in-detector mirror used to construct
        // the rebuilt instance.
        let newSettings = projectedSettings(applying: change)

        switch change.key {
        case "minimumConfidence":
            // Vision uses this as a model parameter (see `detect(in:)`
            // — `request.minimumConfidence = settings.minimumConfidence`).
            // Raising hides detections we already have → `.filter`.
            // Lowering needs detections the model never emitted →
            // detector-tier rebuild.
            return classifyFloatRaiseFilterLowerDetector(change, newSettings: newSettings)

        case "minimumAspectRatio":
            // Lower bound of an acceptance window. Raising narrows
            // (filter); lowering widens (detector).
            return classifyFloatRaiseFilterLowerDetector(change, newSettings: newSettings)

        case "maximumAspectRatio":
            // Upper bound of an acceptance window. Raising widens
            // (detector); lowering narrows (filter).
            return classifyFloatRaiseDetectorLowerFilter(change, newSettings: newSettings)

        case "minimumSize":
            // Lower bound on size. Raising narrows (filter); lowering
            // widens (detector).
            return classifyFloatRaiseFilterLowerDetector(change, newSettings: newSettings)

        case "quadratureToleranceDegrees":
            // Upper bound on angular skew. Raising widens (detector);
            // lowering narrows (filter).
            return classifyFloatRaiseDetectorLowerFilter(change, newSettings: newSettings)

        case "maximumObservations":
            return classifyMaximumObservations(change, newSettings: newSettings)

        case "label":
            // Pure relabel pass over existing detections. Cache stays
            // valid; one filter-pass rewrite.
            return .filter

        default:
            // Unknown key — fall back to the worst-case static tier
            // from the schema. We can't project the change into
            // `settings` (the key isn't a known knob), so the
            // rebuilt detector here is just the current settings;
            // the caller's `TuningModel` should never reach this
            // arm via its keyPath surface.
            return .detector(rebuilt: VisionRectanglesDetector(settings: settings))
        }
    }

    // MARK: - Classifier helpers

    /// Floats where the knob acts as a *lower bound* on the model's
    /// acceptance window: raising narrows the cache-subset (filter),
    /// lowering widens beyond the cache (detector).
    private func classifyFloatRaiseFilterLowerDetector(
        _ change: SettingChange,
        newSettings: VisionRectanglesSettings
    ) -> ApplyResult {
        guard
            case .float(let old) = change.oldValue,
            case .float(let new) = change.newValue
        else {
            // Type-incompatible payload — fall back to worst-case.
            // The rebuilt payload carries the unchanged settings;
            // the next inference re-establishes the cache.
            return .detector(rebuilt: VisionRectanglesDetector(settings: settings))
        }
        if new > old {
            return .filter
        } else {
            // new < old (equal already short-circuited at function entry).
            // Hot-swap doctrine: build a fresh detector with the
            // post-change settings.
            return .detector(rebuilt: VisionRectanglesDetector(settings: newSettings))
        }
    }

    /// Floats where the knob acts as an *upper bound* on the model's
    /// acceptance window: raising widens beyond the cache (detector),
    /// lowering narrows the cache-subset (filter).
    private func classifyFloatRaiseDetectorLowerFilter(
        _ change: SettingChange,
        newSettings: VisionRectanglesSettings
    ) -> ApplyResult {
        guard
            case .float(let old) = change.oldValue,
            case .float(let new) = change.newValue
        else {
            return .detector(rebuilt: VisionRectanglesDetector(settings: settings))
        }
        if new > old {
            return .detector(rebuilt: VisionRectanglesDetector(settings: newSettings))
        } else {
            return .filter
        }
    }

    /// `maximumObservations` has the `0 = unlimited` special case
    /// woven in. See the verdict table in `apply(_:)` for the matrix.
    private func classifyMaximumObservations(
        _ change: SettingChange,
        newSettings: VisionRectanglesSettings
    ) -> ApplyResult {
        guard
            case .int(let old) = change.oldValue,
            case .int(let new) = change.newValue
        else {
            return .detector(rebuilt: VisionRectanglesDetector(settings: settings))
        }

        // Normalize `0` (unlimited) to `Int.max` for comparison.
        // Then "new is a larger cap" ⇒ surfaces previously-truncated
        // observations ⇒ detector; "new is a smaller cap" ⇒ trims
        // existing list ⇒ filter.
        let oldCap = (old == 0) ? Int.max : old
        let newCap = (new == 0) ? Int.max : new
        if newCap > oldCap {
            return .detector(rebuilt: VisionRectanglesDetector(settings: newSettings))
        } else {
            return .filter
        }
    }

    /// Build a `VisionRectanglesSettings` projection that applies
    /// `change` to the detector's current settings. Used by `apply(_:)`
    /// to construct the rebuilt-detector payload without forcing the
    /// caller's `TuningModel` to thread the post-change settings
    /// through a side channel — the detector reads its own current
    /// settings + the change, and produces the new value itself.
    ///
    /// Unknown keys / type-incompatible payloads return the existing
    /// settings unchanged; the caller's classifier arm then routes to
    /// the worst-case `.detector` fallback, which rebuilds with the
    /// *current* settings (a no-op rebuild — correct under the cache-
    /// invalidate-everything Phase 2 shape, just slightly wasteful).
    private func projectedSettings(
        applying change: SettingChange
    ) -> VisionRectanglesSettings {
        var next = settings
        switch (change.key, change.newValue) {
        case ("minimumAspectRatio", .float(let v)): next.minimumAspectRatio = v
        case ("maximumAspectRatio", .float(let v)): next.maximumAspectRatio = v
        case ("minimumSize", .float(let v)): next.minimumSize = v
        case ("maximumObservations", .int(let v)): next.maximumObservations = v
        case ("quadratureToleranceDegrees", .float(let v)): next.quadratureToleranceDegrees = v
        case ("minimumConfidence", .float(let v)): next.minimumConfidence = v
        default:
            // `label` (no SettingKind.string variant yet) and unknown
            // keys land here. The classifier arms above route `label`
            // to `.filter` (no rebuild) and unknown keys to the
            // worst-case `.detector` arm where we rebuild with the
            // unchanged settings.
            break
        }
        return next
    }
}
