import Iris
import SwiftUI
import os

/// M1 smoke test: render the live camera preview full-screen and log a frame
/// timestamp per delivered frame. Run on a physical iPhone (iOS 26+) — the
/// simulator has no camera hardware.
struct ContentView: View {
    @State private var session: CaptureSession?
    @State private var errorText: String?

    var body: some View {
        ZStack {
            if let session {
                CameraPreview(source: session.previewSource, videoGravity: .resizeAspectFill)
                    .ignoresSafeArea()
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
                await MainActor.run { errorText = message }
                return
            }
            await MainActor.run { session = new }
            for await frame in new.frames {
                let width = Int(frame.dimensions.width)
                let height = Int(frame.dimensions.height)
                Logger.demo.info(
                    "frame ts=\(frame.seconds, privacy: .public) size=\(width, privacy: .public)x\(height, privacy: .public)"
                )
            }
        }
    }
}

extension Logger {
    fileprivate static let demo = Logger(subsystem: "iris.demo", category: "capture")
}
