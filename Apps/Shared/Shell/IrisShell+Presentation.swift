import Iris
import SwiftUI
import UniformTypeIdentifiers
import os

// MARK: - Importer + inspector presentation (M9·P3)
//
// File-pickers and the inspector differ enough per platform to warrant routing
// them through small `View` extensions, keeping the shell `body` readable and
// the `#if`s local. The shell exposes the bindings + intent handlers; these
// attach the platform-correct presentation.

extension View {

    /// Attach the single enum-routed file importer (video / image / model).
    @ViewBuilder
    func fileImporting(_ shell: IrisShell) -> some View {
        shell.attachFileImporter(to: self)
    }

    /// Attach the inspector: docked (`.inspector`) at regular width, a bottom
    /// sheet with detents + drag handle at compact width.
    @ViewBuilder
    func inspectorPresentation(_ shell: IrisShell) -> some View {
        shell.attachInspector(to: self)
    }
}

extension IrisShell {

    // MARK: File importer (M9·P5)
    //
    // ONE importer per platform: `importerPresented` presents it,
    // `importTarget` carries WHICH pick flow is up, and the completion
    // dispatches by case through `handlePicked(_:for:)`. Presentation and
    // payload are separate state on purpose — macOS flips `isPresented` to
    // false *before* delivering the completion, so a presentation binding
    // derived from the payload (clearing it on dismissal) races the
    // completion's read and silently drops the pick. See `importTarget`'s doc.
    //
    // The iOS `DocumentPicker` vs. macOS `.fileImporter` divergence is a real
    // platform seam (DocumentPicker keeps the original URL + scope;
    // `.fileImporter` on iOS copies into the sandbox and breaks MRU bookmarks
    // — see `DocumentPicker.swift`), so the *dispatch* is unified even though
    // the SwiftUI surface legitimately differs.

    @ViewBuilder
    func attachFileImporter(to content: some View) -> some View {
        #if os(macOS)
        content.fileImporter(
            isPresented: importerPresentedBinding,
            allowedContentTypes: importTargetValue?.contentTypes ?? [],
            allowsMultipleSelection: false
        ) { result in
            let target = importTargetValue
            clearImportTarget()
            switch result {
            case .success(let urls):
                guard let url = urls.first, let target else {
                    Logger.shell.error("importer dropped pick: \(urls.count) url(s), target=\(target?.rawValue ?? "nil", privacy: .public)")
                    return
                }
                handlePicked(url, for: target)
            case .failure(let error):
                Logger.shell.error("file picker failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        #else
        content.sheet(isPresented: importerPresentedBinding) {
            if let target = importTargetValue {
                DocumentPicker(contentTypes: target.contentTypes) { url in
                    dismissImporter()
                    clearImportTarget()
                    handlePicked(url, for: target)
                }
                .ignoresSafeArea()
            }
        }
        #endif
    }

    // MARK: Inspector

    @ViewBuilder
    func attachInspector(to content: some View) -> some View {
        if isRegularWidth {
            content.inspector(isPresented: inspectorDockedBinding) {
                inspectorContent
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
            }
        } else {
            content.sheet(isPresented: inspectorSheetBinding) {
                inspectorContent
                    .presentationDetents([.height(120), .medium, .large])
                    .presentationBackgroundInteraction(.enabled)
                    .presentationDragIndicator(.visible)
            }
        }
    }
}
