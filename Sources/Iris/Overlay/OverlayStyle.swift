import SwiftUI

/// Per-class color, stroke, and label styling consumed by `DetectionLayer`.
///
/// The locked sketch in
/// `explorations/display-pipeline-architecture/RECOMMENDATIONS.md` §Type
/// sketches names two fields:
///
/// ```swift
/// public let style: OverlayStyle
/// // ...
/// .color(style.color(for: detection.label))
/// .lineWidth(style.strokeWidth)
/// ```
///
/// Phase 6 fills the remaining knobs around those two. The shape kept the
/// `color(for:)` accessor from the sketch (so the call site at the draw
/// pass matches verbatim), with the underlying storage being a closure for
/// flexibility — apps that want a hardcoded `[String: Color]` map can wrap
/// it in a closure at the call site; apps that want a more elaborate
/// strategy (hashed label → palette, confidence-driven hue, etc.) get the
/// same surface.
///
/// **Defaults preserve Phase 5's hardcoded styling** so an `OverlayStyle()`
/// construct produces the same visual output the M2 Phase 5 demo ships.
public struct OverlayStyle: Sendable {

    /// Stroke width applied to every bounding-box outline. `1.5` matches
    /// the Phase 5 hardcoded value.
    public var strokeWidth: CGFloat

    /// Per-class stroke color lookup. Receives the `Detection.label` value
    /// (empty string permitted for class-agnostic detectors) and returns the
    /// SwiftUI `Color` to stroke that detection's box with. The default
    /// returns a fixed cyan accent that matches Phase 5's hardcoded color
    /// regardless of label — apps with per-class palettes override this.
    public var strokeColor: @Sendable (String) -> Color

    /// Formats the label string drawn above each detection's box. Receives
    /// the whole `Detection` so the closure can compose label + confidence
    /// (the default) or do something richer (e.g., a model-aware key).
    /// Returning an empty string suppresses the label backplate entirely
    /// for that detection.
    public var labelFormat: @Sendable (Detection) -> String

    /// Foreground color of the label text. White on the default backplate.
    public var labelTextColor: Color

    /// Backplate behind the label text. Semi-transparent black at 0.6 opacity
    /// matches Phase 5's hardcoded backplate.
    public var labelBackgroundColor: Color

    /// Font of the label text. 11pt semibold matches Phase 5.
    public var labelFont: Font

    public init(
        strokeWidth: CGFloat = 1.5,
        strokeColor: @Sendable @escaping (String) -> Color = { _ in
            Color(red: 0.20, green: 0.85, blue: 1.0)
        },
        labelFormat: @Sendable @escaping (Detection) -> String = { detection in
            let pct = Int((detection.confidence * 100).rounded())
            if detection.label.isEmpty {
                return ""
            }
            return "\(detection.label) \(pct)%"
        },
        labelTextColor: Color = .white,
        labelBackgroundColor: Color = .black.opacity(0.6),
        labelFont: Font = .system(size: 11, weight: .semibold)
    ) {
        self.strokeWidth = strokeWidth
        self.strokeColor = strokeColor
        self.labelFormat = labelFormat
        self.labelTextColor = labelTextColor
        self.labelBackgroundColor = labelBackgroundColor
        self.labelFont = labelFont
    }

    /// Convenience accessor matching the locked-sketch call site
    /// `style.color(for: detection.label)`. Forwards to `strokeColor`.
    public func color(for label: String) -> Color {
        strokeColor(label)
    }

    /// The Phase-5-equivalent default. Stroke and label defaults reproduce
    /// the hardcoded values the M2 Phase 5 demo shipped.
    public static let `default` = OverlayStyle()
}
