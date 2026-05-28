import Foundation

/// Why a frame was flagged for the training set. BRIEF §6's "this was
/// wrong" / "near-miss" affordances, plus an `other` escape hatch.
public enum FlagReason: String, Sendable, Codable, CaseIterable {
    /// The detector got this frame materially wrong (false positive /
    /// missed object / bad box).
    case wrong
    /// The detector was close but not good enough — a borderline / boundary
    /// case worth adding to training.
    case nearMiss
    /// Any other reason the curator wants this frame in the set.
    case other
}

/// A persisted flag record: the frame's canonical address plus the prediction
/// snapshot and curation metadata captured at flag time.
///
/// The `detections` are the model's *predicted* boxes/keypoints at the moment
/// of flagging — provisional annotations that the external annotation tool
/// refines later (M7 extraction writes them into the COCO sidecar in P3/P4).
/// `modelID` / `confidenceThreshold` record the provenance so a flag stays
/// interpretable even after the model or its tuning changes.
public struct FrameFlag: Sendable, Hashable, Codable {

    /// Canonical `(asset, pts)` address of the flagged frame.
    public let ref: FrameRef

    /// Model-predicted detections at flag time (provisional annotations).
    public let detections: [Detection]

    /// Identifier of the model that produced `detections`, if known.
    public let modelID: String?

    /// Confidence threshold in effect when the frame was flagged, if known.
    public let confidenceThreshold: Double?

    /// Why this frame was flagged.
    public let reason: FlagReason

    /// Free-form curator note.
    public let note: String?

    /// When the flag was created.
    public let flaggedAt: Date

    public init(
        ref: FrameRef,
        detections: [Detection],
        modelID: String? = nil,
        confidenceThreshold: Double? = nil,
        reason: FlagReason,
        note: String? = nil,
        flaggedAt: Date = Date()
    ) {
        self.ref = ref
        self.detections = detections
        self.modelID = modelID
        self.confidenceThreshold = confidenceThreshold
        self.reason = reason
        self.note = note
        self.flaggedAt = flaggedAt
    }
}
