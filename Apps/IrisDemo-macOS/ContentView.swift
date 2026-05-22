@preconcurrency import AVFoundation
import Iris
import SwiftUI
import UniformTypeIdentifiers
import os

/// M3 Phase 5 end-to-end smoke. File playback → Vision rectangle detector →
/// `ResultStore` → `DetectionLayer` overlay + `Scrubber`. macOS-only target;
/// the iOS demo (Phase 6) will wire the same stack with a different file
/// picker shape.
///
/// Lifecycle:
/// - `Open Video…` button presents an `.fileImporter` for `.movie` URLs.
/// - On pick: acquire the security-scoped resource (sandbox requirement),
///   build a `PlaybackController(source: PlaybackSource(url:))`, kick off a
///   detector task draining `controller.source.frames`, then `controller.play()`.
/// - On a *new* pick (or view teardown): cancel the prior detector task,
///   `controller.source.invalidate()`, then `stopAccessingSecurityScopedResource()`.
///   That ordering keeps the security-scope alive while AVF still holds the URL.
///
/// `videoRect` for the `DetectionLayer` is read from `playerLayer.videoRect`
/// every TimelineView tick — that's the on-screen rect the video occupies
/// after `.resizeAspect` letterbox/pillarbox, which `PlayerLayerConverter`
/// needs as input. `PlaybackSession.videoRect: AsyncStream<CGRect>` is the
/// eventual reactive plumbing per M3.md §Phase 3; for the smoke demo, the
/// per-tick read is simpler and equivalent.
struct ContentView: View {
    @State private var controller: PlaybackController?
    @State private var resultStore = ResultStore()
    @State private var converter = PlayerLayerConverter()
    @State private var playerLayer: AVPlayerLayer?
    @State private var detectionTask: Task<Void, Never>?
    @State private var activeURL: URL?
    @State private var showFilePicker = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            if let controller {
                playbackArea(controller: controller)

                Scrubber(model: controller)
                    .background(Color(.windowBackgroundColor))

                bottomBar
            } else {
                emptyState
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: Self.movieContentTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                openVideo(at: url)
            case .failure(let error):
                Logger.demo.error(
                    "file picker failed: \(error.localizedDescription, privacy: .public)"
                )
                errorText = "Could not open file: \(error.localizedDescription)"
            }
        }
        // Tear down the active session when the view disappears so the
        // security-scoped resource is released and the AVF observers are
        // unhooked. SwiftUI calls `onDisappear` on window close.
        .onDisappear {
            teardown()
        }
    }

    // MARK: - Sub-views

    /// The `PlaybackView` + `DetectionLayer` stack. The overlay is conditional
    /// on `playerLayer` because `PlayerLayerConverter` needs the AVF layer to
    /// compute `videoRect` — the layer is wired in via `PlaybackView`'s
    /// `onPlayerLayerReady` callback, which fires the first time the view
    /// is built.
    @ViewBuilder
    private func playbackArea(controller: PlaybackController) -> some View {
        ZStack {
            PlaybackView(source: controller.source) { layer in
                // `onPlayerLayerReady` fires inside `makeNSView`. Deferring
                // the `@State` write one runloop tick avoids SwiftUI's
                // "modifying state during view update" warning.
                Task { @MainActor in
                    self.converter = PlayerLayerConverter(playerLayer: layer)
                    self.playerLayer = layer
                }
            }

            if let playerLayer {
                // Outer TimelineView samples `playerLayer.videoRect` at the
                // same ~60 Hz cadence as the overlay's own TimelineView, so
                // window resizes / aspect changes propagate without manual
                // KVO. The overlay still owns its draw-time tick internally.
                TimelineView(.animation(minimumInterval: 1.0 / 60)) { _ in
                    DetectionLayer(
                        store: resultStore,
                        converter: converter,
                        videoRect: playerLayer.videoRect,
                        stalenessThreshold: resultStore.playbackStalenessThreshold,
                        displayTimeSource: { [controller] in
                            controller.currentTime
                        }
                    )
                    .allowsHitTesting(false)
                }
            }
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        HStack {
            if let activeURL {
                Text(activeURL.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Open Video…") { showFilePicker = true }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.windowBackgroundColor))
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 16) {
            if let errorText {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text(errorText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            } else {
                Image(systemName: "film")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("Open a video file to start.")
                    .foregroundStyle(.secondary)
            }
            Button("Open Video…") { showFilePicker = true }
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Lifecycle

    private static let movieContentTypes: [UTType] = [
        .movie, .mpeg4Movie, .quickTimeMovie,
    ]

    /// Construct controller + detector pipeline for the user-selected URL.
    /// Tears down any prior session before swapping in the new one.
    @MainActor
    private func openVideo(at url: URL) {
        // Tear down the previous session BEFORE acquiring the new
        // security-scoped resource — otherwise the prior URL's scope is
        // held longer than necessary.
        teardown()

        guard url.startAccessingSecurityScopedResource() else {
            errorText = "Could not access \(url.lastPathComponent) (security scope denied)."
            Logger.demo.error(
                "startAccessingSecurityScopedResource failed for \(url.path, privacy: .public)"
            )
            return
        }

        let source = PlaybackSource(url: url)
        let newController = PlaybackController(source: source)
        let detector = VisionRectanglesDetector(
            minimumAspectRatio: 0.3,
            maximumAspectRatio: 1.0,
            minimumSize: 0.1,
            minimumConfidence: 0.7,
            label: "rect"
        )

        // Spawn the detector loop. Per the runtime decisions doc the
        // `for await` loop owns task lifetime — we cancel by canceling
        // the wrapping Task. `resultStore` is `@MainActor`, so we hop on
        // each append.
        let store = resultStore
        let task = Task {
            for await frame in source.frames {
                if Task.isCancelled { break }
                do {
                    let detections = try await detector.detect(in: frame)
                    await MainActor.run {
                        store.append(
                            TimestampedDetections(
                                timestamp: frame.timestamp,
                                detections: detections
                            )
                        )
                    }
                } catch {
                    Logger.demo.error(
                        "detect failed: \(String(describing: error), privacy: .public)"
                    )
                }
            }
        }

        self.activeURL = url
        self.controller = newController
        self.detectionTask = task
        self.errorText = nil
        self.playerLayer = nil  // re-bound when PlaybackView attaches

        // Kick off playback through the controller so its state mirror
        // refreshes alongside the source. From `.idle`, `togglePlay()`
        // transitions to `.running`; the controller surfaces AVF errors
        // via the periodic time observer (logged to `iris.playback`).
        newController.togglePlay()
    }

    /// Tear down the active playback session. Idempotent.
    ///
    /// Order: cancel detector → invalidate source → release security scope.
    /// Each step releases a hold on the file URL; reversing the order would
    /// briefly let AVF read from a URL whose security scope has already
    /// been dropped. `invalidate()` is `async`, so the security-scope release
    /// runs after it inside the same `Task` to preserve ordering.
    @MainActor
    private func teardown() {
        detectionTask?.cancel()
        detectionTask = nil

        let priorSource = controller?.source
        let priorURL = activeURL

        controller = nil
        playerLayer = nil
        activeURL = nil
        resultStore.clear()

        // Detach AVF observers + finish the frame stream, then release the
        // security scope. Capturing `priorSource` and `priorURL` locally
        // means a follow-up `openVideo` can reset `@State` to the new
        // session synchronously while AVF tears the old one down in the
        // background.
        Task {
            if let priorSource {
                await priorSource.invalidate()
            }
            if let priorURL {
                priorURL.stopAccessingSecurityScopedResource()
            }
        }
    }
}

extension Logger {
    fileprivate static let demo = Logger(subsystem: "iris.demo", category: "phase5")
}
