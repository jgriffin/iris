import Foundation
import UniformTypeIdentifiers
import os

// MARK: - Shallow folder enumeration (M13·P2)
//
// The folder-sources feature lets Playback / Image pick an entire directory;
// this is the read side — given a folder URL, list its matching children. It
// deliberately stays a plain free function over `FileManager`: no observable
// state, no scope ownership. The *caller* owns the security scope (the folder
// URL comes from a fresh pick or `RecentFolders.resolve()`, both of which carry
// a latent macOS scope the caller must `startAccessingSecurityScopedResource()`
// around — same discipline as `swapToExternal` / `pickImage`). Enumeration
// reads the directory contents while that scope is open; it neither starts nor
// stops it.

/// The content kind a folder listing filters its children to. Playback wants
/// movies, Image wants stills; the per-mode filter is applied here at
/// enumeration time, not baked into storage (one shared folders MRU lists
/// folders regardless of what they hold).
enum FolderContentKind: Hashable {
    case movie
    case image

    /// The base UTType a child must conform to to be included. Conformance
    /// (not exact-type equality) so concrete subtypes — `.quickTimeMovie`,
    /// `.jpeg`, `.heic`, … — all match their umbrella type.
    var baseType: UTType {
        switch self {
        case .movie: return .movie
        case .image: return .image
        }
    }
}

/// Shallow, non-recursive listing of a folder's children matching a content
/// kind. Free function (not a type) — it holds no state and owns no scope; see
/// the file header for the scope contract.
///
/// - Filtering: each child's UTType is taken from `URLResourceValues`
///   (`.contentTypeKey`) rather than re-derived from the path extension, so the
///   filesystem's own type assignment wins (handles extension-less files the
///   system has typed, and avoids a second `UTType(filenameExtension:)` guess).
///   A child is kept when that type conforms to `kind.baseType`. Children whose
///   type can't be read are skipped.
/// - Sorting: Finder-like, `localizedStandardCompare` on the last path
///   component (so `clip2` sorts before `clip10`).
/// - Hidden files: skipped (`.skipsHiddenFiles`).
///
/// - Parameters:
///   - folder: the directory to list. The caller must already hold its
///     security scope (see file header).
///   - kind: which content kind to keep (movies vs. images).
/// - Returns: the matching child URLs, name-sorted. Empty on any enumeration
///   failure (logged), so callers get a clean "nothing matched" rather than a
///   throw to thread through the UI.
@MainActor
func folderListing(of folder: URL, kind: FolderContentKind) -> [URL] {
    let keys: [URLResourceKey] = [.contentTypeKey, .isHiddenKey]
    let children: [URL]
    do {
        children = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )
    } catch {
        Logger.folderListing.error(
            """
            contentsOfDirectory failed for \
            \(folder.lastPathComponent, privacy: .public): \
            \(String(describing: error), privacy: .public)
            """
        )
        return []
    }

    // Large-list handling (scroll-inside vs. a cap + "N more…") is backlogged —
    // deferred at P3 per the user ("push that out for now"); see BOARD §Backlog.
    // No cap today: a shoot folder can hold hundreds of clips and they all list.
    let matching = children.filter { child in
        guard
            let values = try? child.resourceValues(forKeys: [.contentTypeKey]),
            let type = values.contentType
        else {
            return false
        }
        return type.conforms(to: kind.baseType)
    }

    return matching.sorted {
        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
            == .orderedAscending
    }
}

/// Cache key for the shell's per-folder child listing (M13·P3): the folder URL
/// plus the content kind. ONE shared folders MRU serves both modes, so the same
/// folder can be enumerated as movies (Playback) and as stills (Image); the kind
/// keeps those two filtered listings distinct in the cache.
struct FolderChildKey: Hashable {
    let folder: URL
    let kind: FolderContentKind
}

extension Logger {
    static let folderListing = Logger(subsystem: "iris.demo", category: "folder-listing")
}
