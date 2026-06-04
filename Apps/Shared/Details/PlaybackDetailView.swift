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
/// stack, the `Scrubber` (with the flag-marker underlay), and the bottom status
/// bar. The video frame carries NO overlay buttons (redesign) — the Freeze
/// (camera) + Flag affordances live in the window toolbar (`IrisShell`).
///
/// Hosted by `IrisShell`; the shell owns the coordinator, flagging model, and
/// overlay filter. The freeze-from-live hand-off (`inspectFrame`) is fired from
/// the toolbar's camera button against `coordinator.currentFrame`.
struct PlaybackDetailView: View {
    let coordinator: PlaybackDetectionCoordinator
    let flaggingModel: FlaggingModel?
    let filter: OverlayFilter
    let activeLabel: String
    let errorText: String?
    /// First-launch loading state (iOS auto-loads a bundled fixture).
    let isLoadingFixture: Bool
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
        // No on-video overlay buttons (redesign): the Freeze (camera) and Flag
        // affordances moved into the window toolbar — see `IrisShell.detailToolbar`.
        // The video frame stays clean; `onInspect` / `coordinator.currentFrame`
        // are now driven from the toolbar's Freeze button.
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
