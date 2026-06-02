import Iris
import SwiftUI

// MARK: - Shared playback detail (M9·P3·3)
//
// Extracted from the near-identical `playbackArea` / Scrubber / transport /
// bookmark+inspect cluster that lived in both the macOS `ContentView` and the
// iOS `PlaybackContentView`. The two differed mainly in chrome background
// colors — parameterized via `chromeBackground`. The `PlaybackView` +
// `DetectionLayer` + `Scrubber` rendering is hosted intact (not rewritten).

/// The reusable playback detail: the `PlaybackView` + `DetectionLayer` overlay
/// stack, the `Scrubber` (with the flag-marker underlay), the bottom status bar,
/// and the on-frame Inspect + Flag affordances clustered top-right of the video.
///
/// Hosted by `IrisShell`; the shell owns the coordinator, flagging model,
/// overlay filter, and the freeze-from-live hand-off (`onInspect`).
struct PlaybackDetailView: View {
    let coordinator: PlaybackDetectionCoordinator
    let flaggingModel: FlaggingModel?
    let filter: OverlayFilter
    let activeLabel: String
    let errorText: String?
    /// First-launch loading state (iOS auto-loads a bundled fixture).
    let isLoadingFixture: Bool
    /// Direct freeze-from-live: hand the current frame to the shell.
    let onInspect: (Frame?) -> Void
    /// Open-video CTA fired from the empty state.
    let onOpenVideo: () -> Void

    /// Chrome background under the scrubber + status bar. macOS passes the
    /// window background; iOS the system background.
    let chromeBackground: Color

    var body: some View {
        VStack(spacing: 0) {
            if let controller = coordinator.controller {
                playbackArea(controller: controller)

                Scrubber(model: controller) {
                    if let flaggingModel {
                        FlagMarkerStrip(model: flaggingModel, duration: controller.duration)
                    }
                }
                .background(chromeBackground)

                bottomBar
            } else if let errorText {
                errorView(errorText)
            } else if isLoadingFixture {
                ProgressView("Loading fixture…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyState
            }
        }
    }

    @ViewBuilder
    private func playbackArea(controller: PlaybackController) -> some View {
        ZStack {
            PlaybackView(source: controller.source)
                .id(ObjectIdentifier(controller.source))

            DetectionLayer(
                store: coordinator.resultStore,
                makeConverter: { [controller] size in
                    MainActor.assumeIsolated {
                        VideoGeometry(
                            contentSize: controller.presentationSize,
                            containerSize: size,
                            contentMode: .aspectFit
                        )
                    }
                },
                stalenessThreshold: coordinator.resultStore.playbackStalenessThreshold,
                tuning: coordinator.session?.router,
                filter: filter,
                displayTimeSource: { [controller] in
                    MainActor.assumeIsolated { controller.currentTime }
                }
            )
            .allowsHitTesting(false)
        }
        .overlay {
            VideoRectAligned(
                contentSize: controller.presentationSize,
                alignment: .topTrailing
            ) {
                HStack(spacing: 8) {
                    inspectButton
                    if let flaggingModel {
                        FlagButton(model: flaggingModel)
                    }
                }
                .padding(12)
            }
        }
    }

    @ViewBuilder
    private var inspectButton: some View {
        Button {
            onInspect(coordinator.currentFrame)
        } label: {
            Image(systemName: "camera.viewfinder")
                .font(.title3)
                .padding(8)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(coordinator.currentFrame == nil)
        .help("Inspect this frame on the Image page")
        .accessibilityLabel("Inspect frame")
    }

    @ViewBuilder
    private var bottomBar: some View {
        HStack {
            if !activeLabel.isEmpty {
                Text(activeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(coordinator.metrics.compactSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(chromeBackground)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "film")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Open a video file to start.").foregroundStyle(.secondary)
            Button("Open Video…") { onOpenVideo() }
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(message).multilineTextAlignment(.center).padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
