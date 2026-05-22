/// A deterministic `Detector` that returns a pre-configured `[Detection]`
/// from every `detect(in:)` call. Mirrors `MockSource`'s role: SwiftUI
/// `#Preview`s and tests can exercise the detection pipeline without a
/// real model, permissions, or fixtures.
///
/// Stateless — so a plain `struct` is sufficient and `Sendable` falls out
/// for free (per the decision in `plans/DECISIONS.md`: stateless conformers
/// are `struct`, stateful conformers wrap state in an internal `actor`).
public struct MockDetector: Detector {

    public let availability: DetectorAvailability
    public let modelIdentifier: String
    private let detections: [Detection]

    /// Build a mock detector that returns `detections` from every
    /// `detect(in:)` call.
    ///
    /// - Parameters:
    ///   - detections: The detections to return on each call. Pass `[]`
    ///     to mock a detector that ran and found nothing.
    ///   - modelIdentifier: Identifier reported via `modelIdentifier` and
    ///     (independently) settable on the supplied detections by the
    ///     caller. Defaults to `"mock"`.
    ///   - availability: Initial availability. Defaults to `.available`.
    public init(
        detections: [Detection] = [],
        modelIdentifier: String = "mock",
        availability: DetectorAvailability = .available
    ) {
        self.detections = detections
        self.modelIdentifier = modelIdentifier
        self.availability = availability
    }

    public func prewarm() async {
        // Nothing to warm — mock returns a precomputed array.
    }

    public func detect(in frame: Frame) async throws -> [Detection] {
        detections
    }
}
