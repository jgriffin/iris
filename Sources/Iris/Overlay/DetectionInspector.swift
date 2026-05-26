import CoreMedia
import SwiftUI

/// A text-panel inspector that lists, in human-readable form, the exact
/// `[Detection]` the overlay is drawing at the current display time.
///
/// **Why it exists — the diagnostic.** `DetectionInspector` reads the *same*
/// `ResultStore.lookup(at:stale:)` that `DetectionLayer` reads, with an
/// identical call shape (same `displayTimeSource()` and `stalenessThreshold`).
/// So the two views always see the same input. That makes the inspector a
/// render/cache bisector:
///
/// - Inspector lists detections **and** the canvas is blank → render bug.
/// - Inspector is empty **and** the canvas is blank → detector / cache bug.
///
/// **Self-describing.** Every line is derived from the `Detection`'s own
/// fields (`skeleton`, `keypoints`, `readout`, `boundingBox`, `confidence`) —
/// never from the producing detector's capabilities. Self-describing
/// detections is the locked design; the router's `currentDetector` is `any
/// Detector` and doesn't expose capabilities anyway.
///
/// **Cadence.** Driven by a 30 Hz `TimelineView(.animation)` — half the
/// overlay's 60 Hz, since this is a text panel, not pixels chasing motion.
///
/// **Concurrency.** `body` is `@MainActor`; `store.lookup` is `@MainActor` —
/// a direct call, no actor hop. `displayTimeSource` is `@Sendable`.
///
/// **Composition.** The inspector renders as a `VStack` of rows (no inner
/// `ScrollView`) so it nests cleanly inside a host pane that owns the single
/// scroll.
@MainActor
public struct DetectionInspector: View {

    /// The result store to read — the *same* store the overlay reads. Pass the
    /// host's `resultStore`.
    let store: ResultStore

    /// Read each tick to get the current display time. Pass
    /// `{ controller.currentTime }` — identical to the overlay's source.
    let displayTimeSource: @Sendable () -> CMTime

    /// The staleness cap for `lookup`. Pass
    /// `resultStore.playbackStalenessThreshold` — identical to the overlay's.
    let stalenessThreshold: CMTime?

    /// Raw-dump toggle. Off → readable per-detection summaries; on → a
    /// monospaced literal field-by-field dump.
    @State private var showRaw = false

    public init(
        store: ResultStore,
        displayTimeSource: @escaping @Sendable () -> CMTime,
        stalenessThreshold: CMTime?
    ) {
        self.store = store
        self.displayTimeSource = displayTimeSource
        self.stalenessThreshold = stalenessThreshold
    }

    public var body: some View {
        // 30 Hz: lighter than the overlay's 60 Hz — it's a text panel. The
        // lookup call shape MIRRORS DetectionLayer exactly so both views
        // observe the same input at each tick.
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            let time = displayTimeSource()
            let detections = store.lookup(at: time, stale: stalenessThreshold)

            VStack(alignment: .leading, spacing: 10) {
                header(time: time, count: detections.count)

                Toggle("Raw", isOn: $showRaw)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.caption)

                if detections.isEmpty {
                    Text("No detections at this frame.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if showRaw {
                    ForEach(Array(detections.enumerated()), id: \.offset) { _, d in
                        Self.rawDump(d)
                    }
                } else {
                    ForEach(Array(detections.enumerated()), id: \.offset) { _, d in
                        summary(for: d)
                    }
                }
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func header(time: CMTime, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("t = \(Self.seconds(time), specifier: "%.2f")s")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Text(count == 0 ? "no detections" : "\(count) detection\(count == 1 ? "" : "s")")
                .font(.caption.weight(.medium))
                .monospacedDigit()
        }
    }

    // MARK: - Readable summary

    @ViewBuilder
    private func summary(for d: Detection) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // Title: label + secondary sourceModelID + geometry tag.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(d.label.isEmpty ? "(unlabeled)" : d.label)
                    .font(.callout.weight(.medium))
                Text(d.sourceModelID)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Text(Self.geometryTag(d))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }

            if let readout = d.readout {
                Text("\(readout.label): \(readout.text)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            geometryDetail(for: d)
            confidenceDetail(for: d)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        Divider()
    }

    @ViewBuilder
    private func geometryDetail(for d: Detection) -> some View {
        if let kps = d.keypoints, !kps.isEmpty, hasSkeleton(d) || !isQuad(d) {
            // Skeleton / generic keypoints: joint count + expandable list.
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(kps.enumerated()), id: \.offset) { _, kp in
                        Text(Self.keypointLine(kp))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 2)
            } label: {
                Text("\(kps.count) joints")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let corners = Self.quadCorners(d) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(corners.enumerated()), id: \.offset) { _, c in
                    Text(Self.pointLine(c))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text(Self.bboxLine(d.boundingBox))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    /// Confidence, presented honestly. With keypoints, the flat
    /// `detection.confidence` isn't a probability — it's a summary statistic
    /// (typically the mean), so label it `mean` and show the true per-joint
    /// min/mean/max spread. Without keypoints, show the flat value plainly
    /// labeled `confidence (flat)` — no editorializing.
    @ViewBuilder
    private func confidenceDetail(for d: Detection) -> some View {
        if let kps = d.keypoints, !kps.isEmpty {
            let confs = kps.map { Double($0.confidence) }
            let mn = confs.min() ?? 0
            let mx = confs.max() ?? 0
            let mean = confs.reduce(0, +) / Double(confs.count)
            VStack(alignment: .leading, spacing: 1) {
                Text(
                    "conf (per-joint): "
                        + String(format: "%.2f / %.2f / %.2f", mn, mean, mx)
                        + "  (min/mean/max)"
                )
                Text(
                    "flat detection.confidence = "
                        + String(format: "%.2f", d.confidence) + "  (mean)"
                )
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
        } else {
            Text("confidence (flat) = " + String(format: "%.2f", d.confidence))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Raw dump

    /// A monospaced, selectable, field-by-field literal dump of one detection.
    @ViewBuilder
    private static func rawDump(_ d: Detection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(rawDumpString(d))
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
        }
    }

    private static func rawDumpString(_ d: Detection) -> String {
        var lines: [String] = []
        let b = d.boundingBox
        lines.append("label: \"\(d.label)\"")
        lines.append("sourceModelID: \"\(d.sourceModelID)\"")
        lines.append("confidence: \(String(format: "%.4f", d.confidence))")
        lines.append(
            "boundingBox: x=\(String(format: "%.4f", b.origin.x)) "
                + "y=\(String(format: "%.4f", b.origin.y)) "
                + "w=\(String(format: "%.4f", b.size.width)) "
                + "h=\(String(format: "%.4f", b.size.height))"
        )
        if let kps = d.keypoints {
            lines.append("keypoints (\(kps.count)):")
            for kp in kps {
                lines.append(
                    "  [\(kp.name) "
                        + "(\(String(format: "%.4f", kp.position.x)),"
                        + "\(String(format: "%.4f", kp.position.y))) "
                        + "\(String(format: "%.2f", kp.confidence))]"
                )
            }
        } else {
            lines.append("keypoints: nil")
        }
        if let skeleton = d.skeleton {
            lines.append("skeleton: \(skeleton.edges.count) edges")
        } else {
            lines.append("skeleton: nil")
        }
        if let mask = d.mask {
            lines.append("mask: \(mask.width)×\(mask.height)")
        } else {
            lines.append("mask: nil")
        }
        if let readout = d.readout {
            lines.append("readout: \(readout.label) = \"\(readout.text)\"")
        } else {
            lines.append("readout: nil")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Geometry classification (off the detection itself)

    /// `"skeleton"` if the detection carries a skeleton + keypoints; `"quad"`
    /// if it carries the four oriented corner keypoints; else `"box"`.
    private static func geometryTag(_ d: Detection) -> String {
        if d.skeleton != nil, let kps = d.keypoints, !kps.isEmpty { return "skeleton" }
        if quadCorners(d) != nil { return "quad" }
        return "box"
    }

    private func hasSkeleton(_ d: Detection) -> Bool {
        d.skeleton != nil
    }

    private func isQuad(_ d: Detection) -> Bool {
        Self.quadCorners(d) != nil
    }

    /// The four oriented corners, in `topLeft → topRight → bottomRight →
    /// bottomLeft` order, if the detection carries all four corner keypoints.
    /// Mirrors `DetectionLayer.quadCorners(of:)`'s corner-name invariant.
    private static func quadCorners(_ d: Detection) -> [CGPoint]? {
        guard let kps = d.keypoints else { return nil }
        let names = ["topLeft", "topRight", "bottomRight", "bottomLeft"]
        var corners: [CGPoint] = []
        corners.reserveCapacity(4)
        for name in names {
            guard let kp = kps.first(where: { $0.name == name }) else { return nil }
            corners.append(kp.position)
        }
        return corners
    }

    // MARK: - Line formatting

    /// `name — conf — (x, y)` for one keypoint, normalized to 2/3 dp.
    private static func keypointLine(_ kp: Detection.Keypoint) -> String {
        String(
            format: "%@ — %.2f — (%.3f, %.3f)",
            kp.name, kp.confidence, kp.position.x, kp.position.y
        )
    }

    /// `(x, y)` for one corner, normalized to 3 dp.
    private static func pointLine(_ p: CGPoint) -> String {
        String(format: "(%.3f, %.3f)", p.x, p.y)
    }

    /// `bbox = (x, y, w, h)`, normalized to 3 dp.
    private static func bboxLine(_ b: CGRect) -> String {
        String(
            format: "bbox = (%.3f, %.3f, %.3f, %.3f)",
            b.origin.x, b.origin.y, b.size.width, b.size.height
        )
    }

    // MARK: - Time

    /// `CMTime` → seconds, guarding non-finite values (returns 0).
    private static func seconds(_ time: CMTime) -> Double {
        let s = CMTimeGetSeconds(time)
        return s.isFinite ? s : 0
    }
}

// MARK: - Previews

#if DEBUG
@MainActor
private func inspectorPreviewStore() -> ResultStore {
    let store = ResultStore()
    let t = CMTime(value: 100, timescale: 60)
    let detections: [Detection] = [
        // A synthetic tilted quad (four oriented corners).
        Detection(
            boundingBox: CGRect(x: 0.38, y: 0.60, width: 0.28, height: 0.28),
            label: "card",
            confidence: 1.0,
            keypoints: [
                Detection.Keypoint(name: "topLeft", position: CGPoint(x: 0.38, y: 0.82), confidence: 1.0),
                Detection.Keypoint(name: "topRight", position: CGPoint(x: 0.60, y: 0.88), confidence: 1.0),
                Detection.Keypoint(name: "bottomRight", position: CGPoint(x: 0.66, y: 0.66), confidence: 1.0),
                Detection.Keypoint(name: "bottomLeft", position: CGPoint(x: 0.44, y: 0.60), confidence: 1.0),
            ],
            readout: Readout(label: "aspect", text: "1.30:1"),
            sourceModelID: "preview.quad"
        ),
        // A synthetic skeleton (subset of body-pose joints + edges).
        Detection(
            boundingBox: CGRect(x: 0.06, y: 0.40, width: 0.16, height: 0.50),
            label: "person",
            confidence: 0.88,
            keypoints: [
                Detection.Keypoint(name: "nose", position: CGPoint(x: 0.14, y: 0.90), confidence: 0.97),
                Detection.Keypoint(name: "neck", position: CGPoint(x: 0.14, y: 0.84), confidence: 0.95),
                Detection.Keypoint(name: "leftShoulder", position: CGPoint(x: 0.08, y: 0.82), confidence: 0.93),
                Detection.Keypoint(name: "rightShoulder", position: CGPoint(x: 0.20, y: 0.82), confidence: 0.80),
            ],
            skeleton: Skeleton(edges: [
                Skeleton.Edge(from: "nose", to: "neck"),
                Skeleton.Edge(from: "neck", to: "leftShoulder"),
                Skeleton.Edge(from: "neck", to: "rightShoulder"),
            ]),
            readout: Readout(label: "joints", text: "4 joints"),
            sourceModelID: "preview.pose"
        ),
    ]
    store.append(TimestampedDetections(timestamp: t, detections: detections))
    return store
}

#Preview("DetectionInspector · populated") {
    let store = inspectorPreviewStore()
    let frozen = CMTime(value: 100, timescale: 60)
    return ScrollView {
        DetectionInspector(
            store: store,
            displayTimeSource: { frozen },
            stalenessThreshold: store.playbackStalenessThreshold
        )
        .padding()
    }
    .frame(width: 360, height: 480)
}

#Preview("DetectionInspector · empty") {
    let store = ResultStore()
    let frozen = CMTime(value: 100, timescale: 60)
    return DetectionInspector(
        store: store,
        displayTimeSource: { frozen },
        stalenessThreshold: store.playbackStalenessThreshold
    )
    .padding()
    .frame(width: 360)
}
#endif
