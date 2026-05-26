import CoreGraphics
import Testing

@testable import Iris

/// Pure-math coverage of `VideoGeometry`, the single upright-source-normalized →
/// view-point authority.
///
/// `VideoGeometry` does exactly two things: place upright content into a display
/// box (aspect-fit/fill, centered) and flip the y axis (Vision bottom-left →
/// SwiftUI top-left). Orientation (rotation/mirror) is resolved upstream and is
/// deliberately NOT modeled here.
///
/// The baseline cases are the contract: a `VideoGeometry` whose `displayRect`
/// equals the old `videoRect` must reproduce the locked `PlayerLayerConverter`
/// math exactly.
@Suite("VideoGeometry")
struct VideoGeometryTests {

    private let tol: CGFloat = 1e-6

    private func expectClose(
        _ a: CGPoint, _ b: CGPoint,
        _ comment: Comment? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(abs(a.x - b.x) < tol, comment ?? "x", sourceLocation: sourceLocation)
        #expect(abs(a.y - b.y) < tol, comment ?? "y", sourceLocation: sourceLocation)
    }

    private func expectClose(
        _ a: CGRect, _ b: CGRect,
        _ comment: Comment? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(abs(a.minX - b.minX) < tol, comment ?? "minX", sourceLocation: sourceLocation)
        #expect(abs(a.minY - b.minY) < tol, comment ?? "minY", sourceLocation: sourceLocation)
        #expect(abs(a.width - b.width) < tol, comment ?? "width", sourceLocation: sourceLocation)
        #expect(abs(a.height - b.height) < tol, comment ?? "height", sourceLocation: sourceLocation)
    }

    // MARK: - Locked baseline (ported from PlayerLayerConverterTests)

    @Test
    func identitySquareContentFillsSquareContainer() {
        // 720×720 content in a 100×100 container, aspect-fit.
        // displayRect is the whole container; the unit rect maps to it.
        let geo = VideoGeometry(
            contentSize: CGSize(width: 720, height: 720),
            containerSize: CGSize(width: 100, height: 100),
            contentMode: .aspectFit
        )

        expectClose(geo.displayRect, CGRect(x: 0, y: 0, width: 100, height: 100))
        expectClose(
            geo.viewRect(forNormalized: CGRect(x: 0, y: 0, width: 1, height: 1)),
            CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    @Test
    func bottomLeftNormalizedRectMapsToTopLeftViewRectAfterYFlip() {
        // Vision (0,0,0.5,0.5) bottom-left quadrant → bottom half of the view
        // in top-left coords (y origin 50). Matches the locked converter case.
        let geo = VideoGeometry(
            contentSize: CGSize(width: 720, height: 720),
            containerSize: CGSize(width: 100, height: 100),
            contentMode: .aspectFit
        )

        expectClose(
            geo.viewRect(forNormalized: CGRect(x: 0, y: 0, width: 0.5, height: 0.5)),
            CGRect(x: 0, y: 50, width: 50, height: 50))
    }

    @Test
    func topLeftNormalizedRectMapsToTopOfView() {
        // Vision (0,0.5,0.5,0.5) top-left quadrant → top of view (y origin 0).
        let geo = VideoGeometry(
            contentSize: CGSize(width: 720, height: 720),
            containerSize: CGSize(width: 100, height: 100),
            contentMode: .aspectFit
        )

        expectClose(
            geo.viewRect(forNormalized: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)),
            CGRect(x: 0, y: 0, width: 50, height: 50))
    }

    @Test
    func letterboxDisplayRectAndConvertedRect() {
        // 1280×720 (16:9) content in a 100×200 (tall) container, aspect-fit.
        // scale = min(100/1280, 200/720) = 100/1280 = 0.078125
        // displayed = 100 × 56.25; centered vertically → origin.y = 71.875.
        let geo = VideoGeometry(
            contentSize: CGSize(width: 1280, height: 720),
            containerSize: CGSize(width: 100, height: 200),
            contentMode: .aspectFit
        )

        expectClose(geo.displayRect, CGRect(x: 0, y: 71.875, width: 100, height: 56.25))

        // Same normalized rect the locked converter test used:
        // x: 0 + 0.25*100 = 25
        // y: 71.875 + (1 - 0.25 - 0.5)*56.25 = 85.9375
        // w: 50;  h: 28.125
        let converted = geo.viewRect(
            forNormalized: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        #expect(abs(converted.origin.x - 25) < tol)
        #expect(abs(converted.origin.y - 85.9375) < tol)
        #expect(abs(converted.width - 50) < tol)
        #expect(abs(converted.height - 28.125) < tol)
    }

    @Test
    func bottomLeftPointMapsToBottomOfDisplayRect() {
        // Vision (0,0) lands at the bottom (max y) of displayRect; (0,1) at top.
        let geo = VideoGeometry(
            contentSize: CGSize(width: 1280, height: 720),
            containerSize: CGSize(width: 100, height: 200),
            contentMode: .aspectFit
        )
        let dr = geo.displayRect

        let bottom = geo.viewPoint(forNormalized: CGPoint(x: 0, y: 0))
        #expect(abs(bottom.x - dr.minX) < tol)
        #expect(abs(bottom.y - dr.maxY) < tol)

        let top = geo.viewPoint(forNormalized: CGPoint(x: 0, y: 1))
        #expect(abs(top.x - dr.minX) < tol)
        #expect(abs(top.y - dr.minY) < tol)
    }

    // MARK: - displayRect derivation: pillarbox + aspect-fill crop

    @Test
    func pillarboxDisplayRect() {
        // Tall 720×1280 (9:16) content in a wide 200×100 container, aspect-fit.
        // scale = min(200/720, 100/1280) = 100/1280 = 0.078125
        // displayed = 56.25 × 100; centered horizontally → origin.x = 71.875.
        let geo = VideoGeometry(
            contentSize: CGSize(width: 720, height: 1280),
            containerSize: CGSize(width: 200, height: 100),
            contentMode: .aspectFit
        )
        expectClose(geo.displayRect, CGRect(x: 71.875, y: 0, width: 56.25, height: 100))
    }

    @Test
    func aspectFillOverflowsContainerOnOneAxis() {
        // 1280×720 (16:9) content in a 100×200 (tall) container, aspect-FILL.
        // scale = max(100/1280, 200/720) = 200/720 = 0.27778
        // displayed = 355.56 × 200; centered → origin.x = (100-355.56)/2 < 0.
        let geo = VideoGeometry(
            contentSize: CGSize(width: 1280, height: 720),
            containerSize: CGSize(width: 100, height: 200),
            contentMode: .aspectFill
        )
        let dr = geo.displayRect
        // Fills the container height exactly; overflows width (negative x origin,
        // maxX past the container's right edge).
        #expect(abs(dr.height - 200) < tol)
        #expect(dr.minX < 0)
        #expect(dr.maxX > 100)
        #expect(abs(dr.minY) < tol)
    }

    // MARK: - Same truth, different boxes

    @Test
    func sameContentScalesIntoDifferentBoxesConsistently() {
        // The same upright content (1280×720), aspect-fit into two different
        // containers, maps a normalized point to the proportional spot inside
        // each box. Confirms the place+flip is purely a function of displayRect.
        let small = VideoGeometry(
            contentSize: CGSize(width: 1280, height: 720),
            containerSize: CGSize(width: 200, height: 200),
            contentMode: .aspectFit)
        let large = VideoGeometry(
            contentSize: CGSize(width: 1280, height: 720),
            containerSize: CGSize(width: 600, height: 600),
            contentMode: .aspectFit)

        // Center maps to each box's center.
        expectClose(
            small.viewPoint(forNormalized: CGPoint(x: 0.5, y: 0.5)),
            CGPoint(x: small.displayRect.midX, y: small.displayRect.midY))
        expectClose(
            large.viewPoint(forNormalized: CGPoint(x: 0.5, y: 0.5)),
            CGPoint(x: large.displayRect.midX, y: large.displayRect.midY))

        // A non-central point lands at the same FRACTION of each displayRect.
        let p = CGPoint(x: 0.25, y: 0.75)
        for geo in [small, large] {
            let dr = geo.displayRect
            let v = geo.viewPoint(forNormalized: p)
            // x fraction = 0.25; y fraction (top-left) = 1 - 0.75 = 0.25.
            #expect(abs((v.x - dr.minX) / dr.width - 0.25) < tol)
            #expect(abs((v.y - dr.minY) / dr.height - 0.25) < tol)
        }
    }

    // MARK: - Equatable sanity

    @Test
    func valueEqualityHoldsForIdenticalConfigs() {
        let a = VideoGeometry(
            contentSize: CGSize(width: 1280, height: 720),
            containerSize: CGSize(width: 100, height: 200),
            contentMode: .aspectFit)
        let b = VideoGeometry(
            contentSize: CGSize(width: 1280, height: 720),
            containerSize: CGSize(width: 100, height: 200),
            contentMode: .aspectFit)
        #expect(a == b)
    }
}
