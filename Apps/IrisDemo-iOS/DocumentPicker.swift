import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// SwiftUI wrapper around `UIDocumentPickerViewController` configured for
/// movie files. Used by `PlaybackContentView` to let the user pick an
/// arbitrary video off-bundle (demo-ergonomics Phase 2).
///
/// **Why not `.fileImporter`?** `.fileImporter` exists on iOS, but its
/// behavior for `.movie` types on iOS 26 is to copy the file into the app
/// sandbox before delivering the URL — that defeats the purpose of MRU
/// bookmarks (each launch would re-pick a *different* copy). Using
/// `UIDocumentPickerViewController(forOpeningContentTypes:)` directly
/// returns the original URL with a security scope the caller can balance,
/// matching the macOS demo's `NSOpenPanel` flow.
///
/// The picker is presented via `.sheet`; callers bind `isPresented` and
/// receive the picked URL through `onPick`. Cancellation just dismisses
/// the sheet; no callback fires.
struct DocumentPicker: UIViewControllerRepresentable {
    /// Content types the picker accepts. Default mirrors the macOS demo:
    /// any movie-conforming UTI.
    let contentTypes: [UTType]
    /// Called when the user picks a URL. Caller owns
    /// `startAccessingSecurityScopedResource()` / `stopAccessing` —
    /// `DocumentPicker` deliberately does not acquire the scope itself,
    /// because the lifetime extends beyond the picker dismissal.
    let onPick: (URL) -> Void

    init(
        contentTypes: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie],
        onPick: @escaping (URL) -> Void
    ) {
        self.contentTypes = contentTypes
        self.onPick = onPick
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // `asCopy: false` (the default for the open-types initializer) keeps
        // the original URL + a security scope — required for bookmark MRU
        // to be useful across relaunches.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIDocumentPickerViewController,
        context: Context
    ) {
        // No-op — the picker is single-shot per presentation.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            guard let url = urls.first else { return }
            onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            // Nothing to do — sheet dismisses itself.
        }
    }
}
