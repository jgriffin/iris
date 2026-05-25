/// A skeleton's fixed edge topology — which named keypoints connect to which.
/// Edges reference keypoints by NAME (the same names a detector stamps onto
/// `Detection.keypoints`), so rendering never depends on array order. The
/// generic shape lives here; concrete skeletons (e.g. human body pose) are
/// defined by the detector domain that produces them.
public struct Skeleton: Sendable, Hashable {
    public struct Edge: Sendable, Hashable {
        public let from: String
        public let to: String
        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }
    public let edges: [Edge]
    public init(edges: [Edge]) { self.edges = edges }
}
