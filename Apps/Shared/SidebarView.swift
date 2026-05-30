import Iris
import SwiftUI

/// The unified sidebar content (M9·P3): the `MODEL` section pinned to the top
/// (detector picker + the render-time min-confidence slider), the page-rows in
/// the middle (Playback / Image / Capture — the active row expands inline to
/// reveal its `Open…` button + `RECENT` list; inactive rows collapse to a bare
/// label), and a reserved-but-deferred `DATASET` strip pinned to the bottom.
///
/// **One long-lived view.** This is the content of the shell's
/// `NavigationSplitView` sidebar column; it lives for the shell's lifetime.
/// Only row expansion toggles as the active page changes — there is no
/// per-page disappear / reload (that's what removes A4/A7).
///
/// Cross-platform. macOS has no camera, so the Capture row renders disabled
/// there (gated on `captureAvailable`). The file-pick affordances differ per
/// platform (macOS `.fileImporter` vs. iOS `DocumentPicker`); the sidebar only
/// fires intent callbacks (`onOpenVideo` / `onOpenImage`) — the shell owns the
/// platform-specific picker plumbing.
struct SidebarView: View {
    @Binding var page: ShellPage

    // MODEL section.
    let catalog: DetectorCatalog
    let recentDetectors: RecentDetectors
    let modelStore: DemoModelStore
    @Bindable var modelSelection: ModelSelection
    let selectedDetectorID: String

    /// Whether Capture is offered on this platform (false on macOS — no camera).
    let captureAvailable: Bool

    // Playback page.
    let recentVideos: [URL]
    let onOpenVideo: () -> Void
    let onPickVideo: (URL) -> Void

    // Image page.
    let recentImages: [URL]
    let onOpenImage: () -> Void
    let onPickImage: (URL) -> Void

    // DATASET strip (reserved-but-deferred — render a placeholder, wire nothing).
    let exportedFrameCountText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            modelSection
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()

            // Page-rows scroll between the pinned MODEL header and DATASET footer.
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    pageRow(.playback)
                    pageRow(.image)
                    pageRow(.capture)
                }
                .padding(.vertical, 8)
            }

            Spacer(minLength: 0)

            datasetStrip
        }
    }

    // MARK: - MODEL section

    @ViewBuilder
    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MODEL")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Picker("Detector", selection: $modelSelection.detectorID) {
                ForEach(recentDetectors.sortedEntries(catalog)) { entry in
                    detectorRow(for: entry).tag(entry.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityLabel("Active detector")

            // Render-time min-confidence floor — a draw-time OVERLAY filter
            // (what gets drawn), distinct from the per-detector Tune sheet
            // (what the detector emits). One slider drives the shared
            // `ModelSelection`, so every page's overlay honors it. Relocated
            // here from the interim toolbar / control-bar placements (M9·P3).
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Min confidence")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.2f", modelSelection.minConfidence))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $modelSelection.minConfidence, in: 0...1, step: 0.05)
                    .accessibilityLabel("Minimum confidence")
            }
        }
    }

    @ViewBuilder
    private func detectorRow(for entry: DetectorCatalogEntry) -> some View {
        if modelStore.availability(forEntryID: entry.id) == .modelNotReady {
            Text(entry.displayName).foregroundStyle(.secondary)
        } else {
            Text(entry.displayName)
        }
    }

    // MARK: - Page-rows

    /// One page-row. The active row shows a selected style + expands inline to
    /// its `Open…` + `RECENT`; inactive rows are a bare tappable label. The
    /// Capture row is disabled when the platform has no camera.
    @ViewBuilder
    private func pageRow(_ rowPage: ShellPage) -> some View {
        let isActive = page == rowPage
        let disabled = rowPage == .capture && !captureAvailable

        VStack(alignment: .leading, spacing: 6) {
            Button {
                page = rowPage
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: rowPage.systemImage)
                        .frame(width: 20)
                    Text(rowPage.title)
                        .fontWeight(isActive ? .semibold : .regular)
                    Spacer()
                    if isActive {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                    }
                }
                .contentShape(Rectangle())
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(disabled)

            if isActive && !disabled {
                expandedContent(for: rowPage)
                    .padding(.leading, 28)
                    .padding(.trailing, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func expandedContent(for rowPage: ShellPage) -> some View {
        switch rowPage {
        case .playback:
            openButton(title: "Open Video…", systemImage: "folder.badge.plus", action: onOpenVideo)
            recentList(recentVideos, systemImage: "play.rectangle", onPick: onPickVideo, emptyHint: "Use Open Video… to pick a clip.")
        case .image:
            openButton(title: "Open Image…", systemImage: "photo.badge.plus", action: onOpenImage)
            recentList(recentImages, systemImage: "photo", onPick: onPickImage, emptyHint: "Use Open Image… to pick a still.")
        case .capture:
            // Capture has no Open… / RECENT — it's the live camera.
            Text("Live camera")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func openButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func recentList(
        _ recents: [URL],
        systemImage: String,
        onPick: @escaping (URL) -> Void,
        emptyHint: String
    ) -> some View {
        Text("RECENT")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 2)

        if recents.isEmpty {
            Text(emptyHint)
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            ForEach(recents, id: \.self) { url in
                Button {
                    onPick(url)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: systemImage)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Text(url.lastPathComponent)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(url.path)
            }
        }
    }

    // MARK: - DATASET strip (reserved-but-deferred — M8·P6, shelved)

    /// The reserved bottom `DATASET` slot. Renders a disabled placeholder per
    /// the mock; export wiring belongs to the shelved M8·P6 dataset work and is
    /// intentionally NOT hooked up here.
    @ViewBuilder
    private var datasetStrip: some View {
        Divider()
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("DATASET")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(exportedFrameCountText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                // Reserved — export belongs to the shelved M8·P6 dataset work.
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .controlSize(.small)
            .disabled(true)
            .help("Dataset export is reserved (M8·P6, deferred)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// The shell's active page. Routes both the sidebar's active-row expansion and
/// the detail pane. Capture is offered everywhere in the type but rendered
/// disabled where there is no camera (macOS).
enum ShellPage: String, CaseIterable, Identifiable, Hashable {
    case playback, image, capture
    var id: String { rawValue }

    var title: String {
        switch self {
        case .playback: return "Playback"
        case .image: return "Image"
        case .capture: return "Capture"
        }
    }

    var systemImage: String {
        switch self {
        case .playback: return "play.rectangle"
        case .image: return "photo"
        case .capture: return "camera"
        }
    }
}
