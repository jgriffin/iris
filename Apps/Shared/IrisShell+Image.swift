import Iris
import SwiftUI
import UniformTypeIdentifiers
import os

// MARK: - Image detail + lifecycle (M9·P3)
//
// Hosts the shared `ImageDetailView` and owns the image pick / decode / scope /
// MRU plumbing (identical across platforms — the only divergence is the picker
// presentation, gated below).
extension IrisShell {

    @ViewBuilder
    var imageDetail: some View {
        VStack(spacing: 0) {
            ImageDetailView(
                coordinator: imageCoordinator,
                catalog: catalog,
                recentDetectors: recentDetectors,
                modelStore: modelStore,
                selectedDetectorID: imageDetectorBinding,
                showTuning: imageTuningBinding,
                showsControlBar: false
            )
            if let imageErrorText {
                Text(imageErrorText)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
        }
    }

    /// The image detail's detector binding routes through the shared selection
    /// (one global model). Kept as a named accessor so `ImageDetailView`'s
    /// hosting site reads cleanly.
    private var imageDetectorBinding: Binding<String> {
        Binding(get: { selectedDetectorID }, set: { modelSelection.detectorID = $0 })
    }

    private var imageTuningBinding: Binding<Bool> {
        Binding(get: { showImageTuning }, set: { showImageTuning = $0 })
    }

    /// Pick `url`: acquire scope, register MRU, decode to an upright `Frame`,
    /// run detection once, release the PRIOR scope strictly after `setImage`.
    @MainActor
    func pickImage(url: URL) {
        guard let entry = resolvedEntry else { return }
        if page != .image { page = .image }

        guard url.startAccessingSecurityScopedResource() else {
            imageErrorText = "Could not access \(url.lastPathComponent) (security scope denied)."
            Logger.shell.error("startAccessingSecurityScopedResource failed for \(url.path, privacy: .public)")
            return
        }

        withAnimation(.snappy) { recentImages.addOrPromote(url) }

        let frame: Frame
        do {
            frame = try ImageFrameDecoder().frame(fromImageAt: url)
        } catch {
            url.stopAccessingSecurityScopedResource()
            imageErrorText = "Could not decode \(url.lastPathComponent): \(error)"
            Logger.shell.error("image decode failed: \(String(describing: error), privacy: .public)")
            return
        }

        let priorScopedURL = imageScopedURL
        imageScopedURL = url
        imageErrorText = nil
        syncedImageDetectorID = entry.id

        Task { @MainActor in
            await imageCoordinator.setImage(frame, detector: entry)
            if let priorScopedURL { priorScopedURL.stopAccessingSecurityScopedResource() }
        }
    }

    /// Re-run the held image under the shared selection.
    @MainActor
    func selectImageDetector() {
        guard let entry = resolvedEntry else { return }
        syncedImageDetectorID = entry.id
        Task { @MainActor in await imageCoordinator.selectDetector(entry) }
    }

    /// M9·P3·5: direct freeze-from-live. Open `frame` on the Image page under
    /// the SAME detector currently selected — no `InspectorHandoff` conduit, one
    /// shell holds both coordinators so this is a direct call.
    @MainActor
    func inspectFrame(_ frame: Frame?) {
        guard let frame else { return }
        page = .image
        recentDetectors.addOrPromote(id: selectedDetectorID)
        guard let entry = resolvedEntry else { return }
        syncedImageDetectorID = entry.id
        Task { @MainActor in
            await imageCoordinator.setImage(frame, detector: entry)
        }
    }

    func presentImagePicker() {
        #if os(macOS)
        showImagePicker = true
        #else
        showImageDocPicker = true
        #endif
    }
}
