/// A small, capability-honest numeric readout a detector attaches to a
/// detection for display: the meaningful number for THIS detector, never a
/// fake probability. e.g. a rectangle's aspect ratio, a pose's joint count.
/// `text` is display-ready; `label` names the metric (for the P4 inspector).
public struct Readout: Sendable, Hashable {
    public let label: String
    public let text: String
    public init(label: String, text: String) {
        self.label = label
        self.text = text
    }
}
