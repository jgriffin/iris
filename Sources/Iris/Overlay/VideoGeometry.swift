import CoreGraphics

/// The single authority that maps **upright source-frame normalized
/// coordinates** (Vision-native, bottom-left origin, `[0, 1]`) into **SwiftUI
/// view points** (top-left origin). A pure value type: no AVF, no layers, no
/// mutable state — just geometry.
///
/// ## Truth-vs-box model
///
/// By the time detections reach the overlay, **orientation is already resolved
/// upstream**: capture rotates on the `AVCaptureConnection` and stamps the frame
/// `.up`, Vision is handed `frame.orientation`, and the displayed video is
/// upright too. So detection coordinates are normalized to the **upright source
/// frame** — that is the "truth." `VideoGeometry`'s only job is to scale that
/// truth into the on-screen **display box** (aspect-fit letterbox/pillarbox or
/// aspect-fill crop, centered) and flip the y axis from Vision's bottom-left
/// origin to SwiftUI's top-left origin.
///
/// **There is deliberately no rotation or mirroring here.** Those are *source*
/// concerns, handled before a frame ever reaches the overlay. Re-applying them
/// in the overlay would double-apply work already done upstream.
///
/// ## Coordinate conventions
///
/// - **INPUT** — normalized `[0, 1]`, **Vision-native bottom-left origin**.
///   This matches `Detection.boundingBox` and `Detection.Keypoint.position`:
///   `(0, 0)` is the bottom-left of the (upright) source frame content, `(1, 1)`
///   is the top-right. The y axis points **up**.
/// - **OUTPUT** — view points in **SwiftUI top-left origin**. `(0, 0)` is the
///   top-left of the container, y points **down**.
///
/// ## The transform
///
/// `transform` is a single "place + Y-flip" affine matrix mapping the unit
/// square `[0,1]²` (bottom-left origin) onto `displayRect` (top-left origin):
///
/// ```
/// x = displayRect.minX + p.x * displayRect.width
/// y = displayRect.minY + (1 - p.y) * displayRect.height
/// ```
///
/// This is exactly the locked `PlayerLayerConverter` math with
/// `videoRect == displayRect`.
public struct VideoGeometry: NormalizedGeometryConverting, Sendable, Equatable {

    /// Upright source-frame pixel dimensions. Equals `Frame.dimensions`, which
    /// is already upright (orientation resolved upstream) — there is no
    /// pre/post-rotation distinction to make here.
    public var contentSize: CGSize

    /// SwiftUI container size in points, top-left origin.
    public var containerSize: CGSize

    /// How the upright content is fit into the container.
    public var contentMode: ContentMode

    /// Aspect-fit (letterbox/pillarbox, fully visible) vs. aspect-fill (cropped
    /// to fill, overflows on one axis).
    public enum ContentMode: Sendable { case aspectFit, aspectFill }

    public init(
        contentSize: CGSize,
        containerSize: CGSize,
        contentMode: ContentMode
    ) {
        self.contentSize = contentSize
        self.containerSize = containerSize
        self.contentMode = contentMode
    }

    // MARK: - Derived geometry

    /// The on-screen rect the upright content occupies, in view points (top-left
    /// origin), centered in `containerSize` and letterbox/pillarbox- (aspect-fit)
    /// or crop- (aspect-fill) aware.
    ///
    /// - aspect-fit: `scale = min(container/content)` — content fully visible,
    ///   bars on the short axis.
    /// - aspect-fill: `scale = max(container/content)` — content fills the
    ///   container and overflows (negative origin) on the long axis.
    public var displayRect: CGRect {
        guard contentSize.width > 0, contentSize.height > 0,
            containerSize.width > 0, containerSize.height > 0
        else {
            return .zero
        }

        let sx = containerSize.width / contentSize.width
        let sy = containerSize.height / contentSize.height
        let scale: CGFloat
        switch contentMode {
        case .aspectFit: scale = min(sx, sy)
        case .aspectFill: scale = max(sx, sy)
        }

        let displayed = CGSize(
            width: contentSize.width * scale, height: contentSize.height * scale)
        let origin = CGPoint(
            x: (containerSize.width - displayed.width) / 2,
            y: (containerSize.height - displayed.height) / 2
        )
        return CGRect(origin: origin, size: displayed)
    }

    // MARK: - Composed transform

    /// The single "place + Y-flip" affine transform mapping a Vision-normalized
    /// point (bottom-left, `[0,1]²`) to a view point (top-left origin).
    ///
    /// Mapping a point `u` in `[0,1]²`:
    ///   x = rect.minX + u.x * rect.width
    ///   y = rect.minY + (1 - u.y) * rect.height
    /// As an affine matrix (x' = a*x + c*y + tx, y' = b*x + d*y + ty):
    ///   a = rect.width, d = -rect.height, tx = rect.minX, ty = rect.minY + rect.height
    public var transform: CGAffineTransform {
        let rect = displayRect
        return CGAffineTransform(
            a: rect.width, b: 0,
            c: 0, d: -rect.height,
            tx: rect.minX, ty: rect.minY + rect.height
        )
    }

    // MARK: - Conversions

    /// Convert a Vision-normalized point (bottom-left origin, `[0, 1]`) to a
    /// view point (top-left origin), via the composed `transform`.
    public func viewPoint(forNormalized point: CGPoint) -> CGPoint {
        point.applying(transform)
    }

    /// Convert a Vision-normalized rect (bottom-left origin, `[0, 1]`) to a
    /// view rect (top-left origin).
    ///
    /// The rect's four corners are transformed and the **axis-aligned bounding
    /// box** of the results is returned. Since `transform` is an axis-aligned
    /// scale + translate (no rotation), the result is exact — trivially so. For
    /// the identity case this reproduces the locked `PlayerLayerConverter` rect
    /// math against `displayRect`.
    public func viewRect(forNormalized rect: CGRect) -> CGRect {
        let t = transform
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
        ].map { $0.applying(t) }

        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        let minX = xs.min() ?? 0
        let maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0
        let maxY = ys.max() ?? 0
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
