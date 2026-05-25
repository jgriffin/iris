import Testing

@testable import Iris

@Suite("Skeleton")
struct SkeletonTests {

    @Test
    func edgeConstructionRoundTrips() {
        let edge = Skeleton.Edge(from: "neck", to: "nose")
        #expect(edge.from == "neck")
        #expect(edge.to == "nose")
    }

    @Test
    func skeletonConstructionRoundTrips() {
        let skeleton = Skeleton(edges: [
            Skeleton.Edge(from: "a", to: "b"),
            Skeleton.Edge(from: "b", to: "c"),
        ])
        #expect(skeleton.edges.count == 2)
        #expect(skeleton.edges[0] == Skeleton.Edge(from: "a", to: "b"))
    }

    @Test
    func humanBodyPoseHasNonEmptyEdges() {
        #expect(!Skeleton.humanBodyPose.edges.isEmpty)
    }

    @Test
    func humanBodyPoseHasNoSelfEdges() {
        for edge in Skeleton.humanBodyPose.edges {
            #expect(edge.from != edge.to, "Self-edge: \(edge.from)")
        }
    }

    @Test
    func humanBodyPoseEdgeEndpointsAreNonEmpty() {
        for edge in Skeleton.humanBodyPose.edges {
            #expect(!edge.from.isEmpty)
            #expect(!edge.to.isEmpty)
        }
    }
}
