#if os(iOS)
import AVFoundation
import Iris
import SwiftUI

// MARK: - Shared capture detail (M9·P3·3)
//
// Extracted from the prior iOS `CaptureContentView`'s preview + overlay +
// Inspect button. The live `CaptureSession` + detect loop live in the
// shell-owned `CaptureModel` (started/torn-down by the shell off the active
// page); this view only renders the preview, overlay, and affordances. iOS-only
// (macOS has no camera), so the whole file is `#if os(iOS)`.

/// The live-capture detail content: the `CameraPreview` + `DetectionLayer`
/// overlay and the top-right "Inspect frame" affordance.
struct CaptureDetailView: View {
    let capture: CaptureModel
    let filter: OverlayFilter
    let onInspect: (Frame?) -> Void

    var body: some View {
        ZStack {
            if !CaptureModel.cameraAvailable {
                cameraUnavailableView
            } else if let session = capture.session, let converter = capture.converter {
                CameraPreview(
                    source: session.previewSource,
                    videoGravity: .resizeAspectFill,
                    onPreviewLayerReady: { _ in }
                )
                .ignoresSafeArea()

                DetectionLayer(
                    store: capture.resultStore,
                    makeConverter: { _ in converter },
                    filter: filter
                )
                .ignoresSafeArea()
            } else if let session = capture.session {
                // Session up, converter not yet bound: render the preview so the
                // layer-ready callback can supply the converter.
                CameraPreview(
                    source: session.previewSource,
                    videoGravity: .resizeAspectFill,
                    onPreviewLayerReady: { layer in capture.bindConverter(layer) }
                )
                .ignoresSafeArea()
            } else if let errorText = capture.errorText {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text(errorText).multilineTextAlignment(.center).padding()
                }
            } else {
                ProgressView("Starting capture…")
            }
        }
        .overlay(alignment: .topTrailing) {
            if CaptureModel.cameraAvailable, capture.lastFrame != nil {
                Button {
                    onInspect(capture.lastFrame)
                } label: {
                    Image(systemName: "camera.viewfinder")
                        .font(.title3)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Inspect frame")
                .padding(16)
            }
        }
    }

    @ViewBuilder
    private var cameraUnavailableView: some View {
        ContentUnavailableView {
            Label("Camera isn't available here", systemImage: "camera.fill")
        } description: {
            Text(
                """
                The Simulator and Mac (Designed for iPad) have no camera. \
                Run on a physical iPhone to use Capture. Use Playback to work \
                with video files.
                """
            )
        }
    }
}
#endif
