#if DEBUG
import CoreGraphics
import SwiftUI

/// Visual proof for `VideoGeometry`. Each cell renders, stacked:
///   (a) the full container bounds — gray border,
///   (b) a **ground-truth source test card** filling the computed `displayRect`,
///       drawn UPRIGHT (orientation is resolved upstream; `VideoGeometry` does
///       no rotation/mirror), placed with SwiftUI's own `.frame` / `.position`,
///   (c) reference detections + precise alignment probes mapped *through*
///       `VideoGeometry.viewPoint` / `viewRect`, on top of the card,
///   plus the `displayRect` border so letterbox/pillarbox/crop stays legible.
///
/// ## Why two independent code paths
///
/// The card is an **independent oracle**. It is sized and placed with SwiftUI's
/// trusted layout; the overlay probes go through `VideoGeometry`. If
/// `VideoGeometry`'s aspect/placement/Y-flip math agrees with SwiftUI's layout,
/// every probe lands on its feature (the green box is concentric with the
/// circle, each corner dot sits by its `TL`/`TR`/`BL`/`BR` label, the circle
/// stays circular). If `VideoGeometry` is wrong, the misalignment is glaring —
/// because the card never routes through `VideoGeometry`, it cannot "agree with
/// itself."
///
/// ## Truth-vs-box model
///
/// The card represents the UPRIGHT source frame content (the "truth"). The cells
/// vary **source aspect × fit/crop** to prove the one job `VideoGeometry` has:
/// scale the same truth into different display boxes (letterbox / pillarbox /
/// exact / crop) with a correct Y-flip. There are no rotation or mirror cells —
/// those are source concerns resolved before the overlay.
///
/// Because Stage 1 deliberately does NOT touch `DetectionLayer`, the overlay is
/// drawn via a small dedicated `Canvas` (`GeometryProbeCanvas`) straight through
/// `VideoGeometry`, not the live overlay view.

// MARK: - Reference fixture (compact equivalent of previewStore())

/// A single named normalized point in Vision bottom-left space.
private struct ProbeJoint {
    let name: String
    let position: CGPoint
}

/// Edges between joints, by name — a trimmed human-body-pose topology matching
/// the joint set below.
private let probeSkeletonEdges: [(String, String)] = [
    ("nose", "neck"),
    ("neck", "leftShoulder"), ("neck", "rightShoulder"),
    ("leftShoulder", "leftElbow"), ("leftElbow", "leftWrist"),
    ("rightShoulder", "rightElbow"), ("rightElbow", "rightWrist"),
    ("neck", "root"),
    ("root", "leftHip"), ("root", "rightHip"),
    ("leftHip", "leftKnee"), ("leftKnee", "leftAnkle"),
    ("rightHip", "rightKnee"), ("rightKnee", "rightAnkle"),
]

/// 19-joint upright figure in Vision bottom-left normalized coords (head at high
/// y, feet at low y) — the same positions used by `DetectionLayer.previewStore()`.
private let probeJoints: [ProbeJoint] = [
    ProbeJoint(name: "nose", position: CGPoint(x: 0.14, y: 0.92)),
    ProbeJoint(name: "leftEye", position: CGPoint(x: 0.12, y: 0.93)),
    ProbeJoint(name: "rightEye", position: CGPoint(x: 0.16, y: 0.93)),
    ProbeJoint(name: "leftEar", position: CGPoint(x: 0.10, y: 0.92)),
    ProbeJoint(name: "rightEar", position: CGPoint(x: 0.18, y: 0.92)),
    ProbeJoint(name: "neck", position: CGPoint(x: 0.14, y: 0.86)),
    ProbeJoint(name: "leftShoulder", position: CGPoint(x: 0.08, y: 0.84)),
    ProbeJoint(name: "rightShoulder", position: CGPoint(x: 0.20, y: 0.84)),
    ProbeJoint(name: "leftElbow", position: CGPoint(x: 0.06, y: 0.72)),
    ProbeJoint(name: "rightElbow", position: CGPoint(x: 0.22, y: 0.72)),
    ProbeJoint(name: "leftWrist", position: CGPoint(x: 0.07, y: 0.60)),
    ProbeJoint(name: "rightWrist", position: CGPoint(x: 0.21, y: 0.60)),
    ProbeJoint(name: "root", position: CGPoint(x: 0.14, y: 0.58)),
    ProbeJoint(name: "leftHip", position: CGPoint(x: 0.11, y: 0.56)),
    ProbeJoint(name: "rightHip", position: CGPoint(x: 0.17, y: 0.56)),
    ProbeJoint(name: "leftKnee", position: CGPoint(x: 0.10, y: 0.32)),
    ProbeJoint(name: "rightKnee", position: CGPoint(x: 0.18, y: 0.32)),
    ProbeJoint(name: "leftAnkle", position: CGPoint(x: 0.09, y: 0.08)),
    ProbeJoint(name: "rightAnkle", position: CGPoint(x: 0.19, y: 0.08)),
]

/// Circle radius as a fraction of the card's SHORTER axis. The overlay's
/// circle-hugging box uses the same fraction in normalized coords, so the box's
/// half-width/half-height each equal this. On a non-square box the green box is
/// wider or taller than the circle (matching the circle's normalized extents) —
/// that is correct, not a bug.
private let circleRadiusFraction: CGFloat = 0.30

/// Corner probe dots in Vision bottom-left normalized space. Each should land
/// adjacent to its card corner label:
///   (0.1, 0.9) → TL   (0.9, 0.9) → TR
///   (0.1, 0.1) → BL   (0.9, 0.1) → BR
/// (Vision y points up, so high y is the top of the source frame.)
private let cornerProbes: [(label: String, point: CGPoint)] = [
    ("TL", CGPoint(x: 0.1, y: 0.9)),
    ("TR", CGPoint(x: 0.9, y: 0.9)),
    ("BL", CGPoint(x: 0.1, y: 0.1)),
    ("BR", CGPoint(x: 0.9, y: 0.1)),
]

// MARK: - Ground-truth source test card (the INDEPENDENT oracle)

/// The upright SOURCE frame content, authored in source space (top-left origin,
/// like all SwiftUI views) and drawn UPRIGHT. Placement (size + center) is done
/// by the caller with SwiftUI layout, never `VideoGeometry`. This is what the
/// overlay probes are judged against.
private struct SourceTestCard: View {
    /// Circle radius as a fraction of the shorter card axis (matches
    /// `circleRadiusFraction` so the overlay's circle-hugging box lines up).
    let circleRadiusFraction: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height

            // Background so the card reads against the container.
            ctx.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(Color(white: 0.16)))

            // Light grid at 0.1 normalized spacing.
            var grid = Path()
            for i in 1..<10 {
                let x = w * CGFloat(i) / 10
                grid.move(to: CGPoint(x: x, y: 0))
                grid.addLine(to: CGPoint(x: x, y: h))
                let y = h * CGFloat(i) / 10
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: w, y: y))
            }
            ctx.stroke(grid, with: .color(.white.opacity(0.12)), lineWidth: 0.5)

            // Centered circle (outline). Radius keyed off the shorter axis so it
            // stays a true circle iff aspect is preserved — an ellipse means a
            // w/h scale bug in whatever placed the card.
            let r = min(w, h) * circleRadiusFraction
            let circleRect = CGRect(
                x: w / 2 - r, y: h / 2 - r, width: 2 * r, height: 2 * r)
            ctx.stroke(
                Path(ellipseIn: circleRect),
                with: .color(.orange), lineWidth: 2)

            // Corner labels TL/TR/BL/BR (card is upright in SwiftUI top-left
            // space, so TOP is screen-up).
            let inset: CGFloat = 4
            drawCorner(ctx, "TL", at: CGPoint(x: inset, y: inset), anchor: .topLeading, w: w, h: h)
            drawCorner(ctx, "TR", at: CGPoint(x: w - inset, y: inset), anchor: .topTrailing, w: w, h: h)
            drawCorner(ctx, "BL", at: CGPoint(x: inset, y: h - inset), anchor: .bottomLeading, w: w, h: h)
            drawCorner(ctx, "BR", at: CGPoint(x: w - inset, y: h - inset), anchor: .bottomTrailing, w: w, h: h)

            // Bold asymmetric orientation glyph: a large "F" near top-center. It
            // confirms the card is drawn upright (and would expose any stray
            // flip), even though VideoGeometry itself applies none.
            let f = ctx.resolve(
                Text("F").font(.system(size: min(w, h) * 0.34, weight: .black)).foregroundColor(.cyan))
            ctx.draw(f, at: CGPoint(x: w / 2, y: h * 0.22), anchor: .center)
        }
    }

    private func drawCorner(
        _ ctx: GraphicsContext, _ text: String, at point: CGPoint,
        anchor: UnitPoint, w: CGFloat, h: CGFloat
    ) {
        let resolved = ctx.resolve(
            Text(text).font(.system(size: min(w, h) * 0.09, weight: .bold).monospaced())
                .foregroundColor(.white.opacity(0.85)))
        ctx.draw(resolved, at: point, anchor: anchor)
    }
}

// MARK: - Overlay probe canvas (the VideoGeometry path)

/// Draws the `displayRect` border + reference detections + alignment probes
/// through `VideoGeometry`. Independent of `DetectionLayer` by design (Stage 1).
private struct GeometryProbeCanvas: View {
    let geometry: VideoGeometry

    var body: some View {
        Canvas { ctx, _ in
            let dr = geometry.displayRect

            // displayRect border (card fills it from underneath; keep the border
            // so bars/crop stay visible).
            ctx.stroke(Path(dr), with: .color(.secondary), lineWidth: 1)

            // Circle-hugging box: centered at (0.5,0.5), half-extent equal to the
            // circle's normalized radius (the same fraction the card uses).
            let f = circleRadiusFraction
            let hugBox = CGRect(x: 0.5 - f, y: 0.5 - f, width: 2 * f, height: 2 * f)
            ctx.stroke(
                Path(geometry.viewRect(forNormalized: hugBox)),
                with: .color(.green), style: StrokeStyle(lineWidth: 2))

            // Skeleton edges.
            let jointByName = Dictionary(
                uniqueKeysWithValues: probeJoints.map { ($0.name, $0.position) })
            var edgePath = Path()
            for (from, to) in probeSkeletonEdges {
                guard let a = jointByName[from], let b = jointByName[to] else { continue }
                edgePath.move(to: geometry.viewPoint(forNormalized: a))
                edgePath.addLine(to: geometry.viewPoint(forNormalized: b))
            }
            ctx.stroke(
                edgePath, with: .color(.cyan),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

            // Skeleton joints (small dots).
            for joint in probeJoints {
                let p = geometry.viewPoint(forNormalized: joint.position)
                let r: CGFloat = 2.0
                ctx.fill(
                    Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                    with: .color(.yellow))
            }

            // Four corner probe dots — each should land by its TL/TR/BL/BR label.
            for probe in cornerProbes {
                let p = geometry.viewPoint(forNormalized: probe.point)
                let r: CGFloat = 4.0
                ctx.fill(
                    Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                    with: .color(.red))
                let tag = ctx.resolve(
                    Text(probe.label).font(.system(size: 8, weight: .bold).monospaced())
                        .foregroundColor(.red))
                ctx.draw(tag, at: CGPoint(x: p.x, y: p.y - 8), anchor: .center)
            }
        }
    }
}

// MARK: - Cell (card oracle + overlay probes, stacked)

/// One labeled gallery cell. The card fills `displayRect` upright (always
/// `dr.size`), placed with SwiftUI layout, and is clipped to the container so an
/// aspect-fill crop is visible. The overlay probes are drawn on top through
/// `VideoGeometry`.
private struct GeometryCell: View {
    let title: String
    let geometry: VideoGeometry

    var body: some View {
        let container = geometry.containerSize
        let dr = geometry.displayRect

        return VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.monospaced())
                .foregroundStyle(.primary)

            ZStack(alignment: .topLeading) {
                Color(white: 0.06)

                // (b) Ground-truth card — INDEPENDENT oracle. Upright: it just
                // fills displayRect and centers there (no VideoGeometry, no
                // rotation/mirror).
                SourceTestCard(circleRadiusFraction: circleRadiusFraction)
                    .frame(width: dr.width, height: dr.height)
                    .position(x: dr.midX, y: dr.midY)

                // (c) Overlay probes — the VideoGeometry path, judged against (b).
                GeometryProbeCanvas(geometry: geometry)
            }
            .frame(width: container.width, height: container.height)
            .clipped()  // aspect-fill crop becomes visible at the container edge.
            // (a) full container bounds.
            .border(Color.gray.opacity(0.6), width: 1)
        }
    }
}

// MARK: - Gallery

#Preview("VideoGeometry · gallery") {
    let squareContainer = CGSize(width: 200, height: 200)

    ScrollView {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 200), spacing: 16)],
            spacing: 16
        ) {
            // fit · letterbox: wide content in a TALL container → top/bottom bars.
            GeometryCell(
                title: "fit · letterbox (1280×720 → tall)",
                geometry: VideoGeometry(
                    contentSize: CGSize(width: 1280, height: 720),
                    containerSize: CGSize(width: 160, height: 220),
                    contentMode: .aspectFit))

            // fit · pillarbox: tall content in a WIDE container → side bars.
            GeometryCell(
                title: "fit · pillarbox (720×1280 → wide)",
                geometry: VideoGeometry(
                    contentSize: CGSize(width: 720, height: 1280),
                    containerSize: CGSize(width: 240, height: 160),
                    contentMode: .aspectFit))

            // fit · exact: matching aspect → no bars (sanity).
            GeometryCell(
                title: "fit · exact (square → square)",
                geometry: VideoGeometry(
                    contentSize: CGSize(width: 480, height: 480),
                    containerSize: squareContainer,
                    contentMode: .aspectFit))

            // fill · crop landscape: wide content into a square box → sides cropped.
            GeometryCell(
                title: "fill · crop landscape (1280×720 → square)",
                geometry: VideoGeometry(
                    contentSize: CGSize(width: 1280, height: 720),
                    containerSize: squareContainer,
                    contentMode: .aspectFill))

            // fill · crop portrait: tall content into a square box → top/bottom cropped.
            GeometryCell(
                title: "fill · crop portrait (720×1280 → square)",
                geometry: VideoGeometry(
                    contentSize: CGSize(width: 720, height: 1280),
                    containerSize: squareContainer,
                    contentMode: .aspectFill))

            // Same truth, different boxes — identical 1280×720 source scaled into
            // a small vs. a large box. The overlay tracks the box in both: proof
            // that placement is purely a function of displayRect.
            GeometryCell(
                title: "same truth · small box (1280×720)",
                geometry: VideoGeometry(
                    contentSize: CGSize(width: 1280, height: 720),
                    containerSize: CGSize(width: 160, height: 160),
                    contentMode: .aspectFit))

            GeometryCell(
                title: "same truth · large box (1280×720)",
                geometry: VideoGeometry(
                    contentSize: CGSize(width: 1280, height: 720),
                    containerSize: CGSize(width: 300, height: 300),
                    contentMode: .aspectFit))
        }
        .padding(16)
    }
    .frame(width: 780, height: 760)
}
#endif
