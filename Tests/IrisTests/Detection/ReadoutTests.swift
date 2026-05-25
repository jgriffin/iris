import Testing

@testable import Iris

/// Construction / equality coverage for `Readout` — the capability-honest
/// numeric readout a detector stamps onto a `Detection`.
@Suite("Readout")
struct ReadoutTests {

    @Test
    func constructsWithLabelAndText() {
        let readout = Readout(label: "aspect", text: "1.42:1")
        #expect(readout.label == "aspect")
        #expect(readout.text == "1.42:1")
    }

    @Test
    func equatableByLabelAndText() {
        let a = Readout(label: "joints", text: "19 joints")
        let b = Readout(label: "joints", text: "19 joints")
        let c = Readout(label: "joints", text: "18 joints")
        let d = Readout(label: "aspect", text: "19 joints")
        #expect(a == b)
        #expect(a != c)
        #expect(a != d)
    }

    @Test
    func hashableInASet() {
        let set: Set<Readout> = [
            Readout(label: "aspect", text: "1.30:1"),
            Readout(label: "aspect", text: "1.30:1"),
            Readout(label: "joints", text: "19 joints"),
        ]
        #expect(set.count == 2)
    }
}
