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

    // MARK: Fixture folders (M13·P3 design-gallery)
    //
    // Plain `FoldersBlock.Folder` data for the FOLDER-block gallery. The URLs
    // point at paths that needn't exist — `FolderBlock`/`FoldersBlock` take the
    // already-enumerated children directly, so nothing is read from disk.

    private static func folder(_ path: String, _ names: [String]) -> FoldersBlock.Folder {
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        return FoldersBlock.Folder(
            url: dir,
            children: names.map { dir.appendingPathComponent($0) }
        )
    }

    /// A realistic shoot dump (~6 clips), an exports folder (2), and an empty
    /// one — the video-side folder fixtures for the placement/presentation
    /// gallery.
    static let sampleVideoFolders: [FoldersBlock.Folder] = [
        folder("/Volumes/Shoots/2026-06-04 capture", [
            "GX010012.mov", "GX010013.mov", "GX010014.mov",
            "GX010015.mov", "GX010016.mov", "GX010017.mov",
        ]),
        folder("/Volumes/Shoots/renders", [
            "Highlight-Reel-v3.mp4", "Slow-Mo-Export.mov",
        ]),
        emptyVideoFolderData,
    ]

    /// An empty video folder on its own — drives the "no matching files" case.
    static let sampleEmptyVideoFolder = emptyVideoFolderData
    private static let emptyVideoFolderData =
        folder("/Volumes/Shoots/empty-dump", [])

    /// A ~12-child folder — exercises the large-folder shape that P4's cap will
    /// target (no cap yet; the block lists them all today).
    static let sampleManyVideoFolder: FoldersBlock.Folder =
        folder("/Volumes/Shoots/2026-05-31 marathon", (1...12).map {
            String(format: "GX0100%02d.mov", $0)
        })

    /// The image-side fixtures: a frame-grab dump (~6 stills) and a small
    /// renders folder.
    static let sampleImageFolders: [FoldersBlock.Folder] = [
        folder("/Volumes/Shoots/frame-grabs", [
            "Frame-00001.png", "Frame-00128.png", "Frame-00421.png",
            "Frame-00640.png", "Frame-00777.png", "Frame-01024.png",
        ]),
        folder("/Volumes/Shoots/edited", [
            "Court-Still.jpg", "Net-Closeup.heic",
        ]),
    ]
}
#endif
