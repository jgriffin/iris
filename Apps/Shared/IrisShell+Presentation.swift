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

    /// Attach the video (and, on macOS, the routed model) importer.
    @ViewBuilder
    func videoImporter(_ shell: IrisShell) -> some View {
        shell.attachVideoImporter(to: self)
    }

    /// Attach the image importer.
    @ViewBuilder
    func imageImporter(_ shell: IrisShell) -> some View {
        shell.attachImageImporter(to: self)
    }

    /// Attach the inspector: docked (`.inspector`) at regular width, a bottom
    /// sheet with detents + drag handle at compact width.
    @ViewBuilder
    func inspectorPresentation(_ shell: IrisShell) -> some View {
        shell.attachInspector(to: self)
    }
}

extension IrisShell {

    // MARK: Video / model importer

    @ViewBuilder
    func attachVideoImporter(to content: some View) -> some View {
        #if os(macOS)
        content.fileImporter(
            isPresented: Binding(
                get: { activeImporterValue != nil },
                set: { if !$0 { clearActiveImporter() } }
            ),
            allowedContentTypes: activeImporterValue?.contentTypes ?? [],
            allowsMultipleSelection: false
        ) { result in
            let importer = activeImporterValue
            clearActiveImporter()
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                switch importer {
                case .movie: swapToExternal(url: url)
                case .model: loadPickedModel(at: url)
                case nil: break
                }
            case .failure(let error):
                Logger.shell.error("video/model picker failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        #else
        content
            .sheet(isPresented: videoPickerBinding) {
                DocumentPicker(contentTypes: Self.movieContentTypes) { url in
                    setVideoPicker(false)
                    swapToExternal(url: url)
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: modelPickerBinding) {
                DocumentPicker(contentTypes: Self.modelContentTypes) { url in
                    setModelPicker(false)
                    loadPickedModel(at: url)
                }
                .ignoresSafeArea()
            }
        #endif
    }

    // MARK: Image importer

    @ViewBuilder
    func attachImageImporter(to content: some View) -> some View {
        #if os(macOS)
        content.fileImporter(
            isPresented: imagePickerBinding,
            allowedContentTypes: Self.imageContentTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                pickImage(url: url)
            case .failure(let error):
                Logger.shell.error("image picker failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        #else
        content.sheet(isPresented: imagePickerBinding) {
            DocumentPicker(contentTypes: Self.imageContentTypes) { url in
                setImagePicker(false)
                pickImage(url: url)
            }
            .ignoresSafeArea()
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
