@preconcurrency import AVFoundation
import Iris
import SwiftUI
import os

/// M2 Phase 7 end-to-end smoke. Live camera → Vision rectangle detector →
/// `ResultStore` → `DetectionLayer` overlay, full-screen. Run on a physical
/// iPhone (iOS 26+) — the simulator has no camera hardware.
struct ContentView: View {
    @State private var session: CaptureSession?
    @State private var resultStore = ResultStore()
    @State private var converter: PreviewLayerConverter?
    @State private var errorText: String?

    var body: some View {
        ZStack {
            if let session {
                CameraPreview(
                    source: session.previewSource,
                    videoGravity: .resizeAspectFill,
                    onPreviewLayerReady: { layer in
                        Task { @MainActor in
                            converter = PreviewLayerConverter(previewLayer: layer)
                        }
                    }
                )
                .ignoresSafeArea()

                if let converter {
                    DetectionLayer(
                        store: resultStore,
                        converter: converter,
                        videoRect: .zero  // unused by PreviewLayerConverter
                    )
                    .ignoresSafeArea()
                }
            } else if let errorText {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                    Text(errorText)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            } else {
                ProgressView("Starting capture…")
            }
        }
        .task {
            let new = CaptureSession()
            do {
                try await new.start()
            } catch {
                let message = "Capture start failed: \(error)"
                Logger.demo.error("\(message, privacy: .public)")
                errorText = message
                return
            }
            session = new

            // Vision default `maximumAspectRatio` of 0.5 only accepts narrow
            // rects (Phase 3 footgun). 1.0 accepts squares too;
            // `minimumConfidence: 0.5` filters out the noisy long-tail.
            let detector = VisionRectanglesDetector(
                minimumAspectRatio: 0.3,
                maximumAspectRatio: 1.0,
                minimumSize: 0.1,
                minimumConfidence: 0.7,
                label: "rect"
            )

            for await frame in new.frames {
                do {
                    let detections = try await detector.detect(in: frame)
                    resultStore.append(
                        TimestampedDetections(timestamp: frame.timestamp, detections: detections)
                    )
                } catch {
                    let message = String(describing: error)
                    Logger.demo.error("detect failed: \(message, privacy: .public)")
                }
            }
        }
    }
}

extension Logger {
    fileprivate static let demo = Logger(subsystem: "iris.demo", category: "phase7")
}
