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
public struct VisionRectanglesDetector: Detector {

    /// Minimum aspect ratio (short-side / long-side) for accepted
    /// rectangles. Mirrors `DetectRectanglesRequest.minimumAspectRatio`.
    /// Defaults to `0.5` (Vision's own default for revision 1).
    public let minimumAspectRatio: Float

    /// Maximum aspect ratio for accepted rectangles. Mirrors
    /// `DetectRectanglesRequest.maximumAspectRatio`. Defaults to `0.5` —
    /// matching Vision's default, which is the *minimum* allowed value.
    /// Set higher (e.g. `1.0`) to accept squares; the Vision default of
    /// `0.5` is intentionally narrow.
    public let maximumAspectRatio: Float

    /// Smallest accepted rectangle as a fraction of the shortest image
    /// dimension. Mirrors `DetectRectanglesRequest.minimumSize`. Defaults
    /// to Vision's own default of `0.2`.
    public let minimumSize: Float

    /// Maximum number of rectangles to return. `0` means unlimited; mirrors
    /// Vision's default.
    public let maximumObservations: Int

    /// How far each corner is allowed to deviate from 90° (in degrees).
    /// Mirrors `DetectRectanglesRequest.quadratureToleranceDegrees`.
    /// Defaults to Vision's own default of `30.0`.
    public let quadratureToleranceDegrees: Float

    /// Minimum confidence for a rectangle to be returned. Mirrors
    /// `DetectRectanglesRequest.minimumConfidence`. Defaults to `0.0` so the
    /// adapter is permissive by default; callers tune via init.
    public let minimumConfidence: Float

    /// Label applied to every emitted `Detection`. Public so callers can
    /// override (e.g. `"document"` for a doc-scanner use case) without
    /// re-wrapping the detector.
    public let label: String

    public let availability: DetectorAvailability = .available

    public let modelIdentifier: String = "vision.rectangles"

    public init(
        minimumAspectRatio: Float = 0.5,
        maximumAspectRatio: Float = 0.5,
        minimumSize: Float = 0.2,
        maximumObservations: Int = 0,
        quadratureToleranceDegrees: Float = 30.0,
        minimumConfidence: Float = 0.0,
        label: String = "rectangle"
    ) {
        self.minimumAspectRatio = minimumAspectRatio
        self.maximumAspectRatio = maximumAspectRatio
        self.minimumSize = minimumSize
        self.maximumObservations = maximumObservations
        self.quadratureToleranceDegrees = quadratureToleranceDegrees
        self.minimumConfidence = minimumConfidence
        self.label = label
    }

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
        request.minimumAspectRatio = minimumAspectRatio
        request.maximumAspectRatio = maximumAspectRatio
        request.minimumSize = minimumSize
        request.maximumObservations = maximumObservations
        request.quadratureToleranceDegrees = quadratureToleranceDegrees
        request.minimumConfidence = minimumConfidence

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
                label: label,
                confidence: observation.confidence,
                keypoints: keypoints,
                sourceModelID: modelIdentifier
            )
        }
    }
}
