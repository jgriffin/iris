#if DEBUG
import Foundation
import Iris

/// Reusable sample state for SwiftUI previews of the demo shell (M9·P6·1).
///
/// All persisted models are built against a **throwaway** `UserDefaults`
/// suite (`"iris.preview"`) so rendering a preview never reads or clobbers the
/// real demo defaults. The sample recent URLs point at `/tmp` files that never
/// get opened — they exist only so the `RECENT` list draws realistic rows.
@MainActor
enum PreviewFixtures {
    /// A throwaway defaults suite shared by the preview-only models. Distinct
    /// from `.standard` so previews are hermetic.
    static let defaults = UserDefaults(suiteName: "iris.preview")!

    /// Sample app-level model selection: the Vision rectangles detector at a
    /// mid-ish confidence floor.
    static var modelSelection: ModelSelection {
        let sel = ModelSelection(defaults: defaults)
        sel.detectorID = "vision.rectangles"
        sel.minConfidence = 0.4
        return sel
    }

    /// A `RecentDetectors` MRU pre-populated with real catalog ids so the
    /// detector picker shows a remembered order. Latest-promoted floats first,
    /// so the resulting MRU is `[yolo26n, yolo12n, rectangles]`.
    static var recentDetectors: RecentDetectors {
        let recents = RecentDetectors(defaults: defaults, key: "iris.preview.detectors")
        recents.addOrPromote(id: "vision.rectangles")
        recents.addOrPromote(id: DemoCatalog.yolo12nEntryID)
        recents.addOrPromote(id: DemoCatalog.yolo26nEntryID)
        return recents
    }

    /// A fresh model store. Bundled models aren't present in a preview build,
    /// so the catalog surfaces the Vision entries plus the custom placeholder.
    static var modelStore: DemoModelStore { DemoModelStore() }

    /// The demo detector catalog built against `modelStore`.
    static func catalog(store: DemoModelStore) -> DetectorCatalog {
        DemoCatalog.detectors(store: store)
    }

    /// Sample recent-video URLs with realistic filenames (never opened).
    static let sampleVideoURLs: [URL] = [
        URL(fileURLWithPath: "/tmp/Soccer-Match-01.mov"),
        URL(fileURLWithPath: "/tmp/Backyard-Drill.mp4"),
    ]

    /// Sample recent-image URLs with realistic filenames (never opened).
    static let sampleImageURLs: [URL] = [
        URL(fileURLWithPath: "/tmp/Frame-00421.png"),
        URL(fileURLWithPath: "/tmp/Court-Still.jpg"),
    ]
}
#endif
