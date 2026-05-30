import Iris
import SwiftUI

/// The unified sidebar content (M9·P3): the `MODEL` section pinned to the top
/// (detector picker + the render-time min-confidence slider), the page-rows in
/// the middle (Playback / Image / Capture — the active row expands inline to
/// reveal its `Open…` button + `RECENT` list; inactive rows collapse to a bare
/// label), and a `DATASET` strip pinned to the bottom (macOS-only export
/// controls; read-only exported-frame count everywhere).
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

    // DATASET strip. macOS-only export controls (iOS exposes Documents via
    // Files.app and never had this footer); the count line shows everywhere.
    let exportedFrameCountText: String
    /// Whether a dataset sweep is currently running (drives the progress spinner
    /// + disables the button). Always `false` on platforms without a coordinator.
    let isSweeping: Bool
    /// The last sweep's one-line summary, if any.
    let lastSummaryText: String?
    /// Export all flagged frames now. `nil` until a coordinator exists.
    let onExportNow: (() async -> Void)?
    /// Reveal the exported-frames folder in Finder. macOS-only (`nil` on iOS).
    let onRevealInFinder: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            modelSection
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()

            // Page-rows scroll between the pinned MODEL header and DATASET footer.
            // Horizontal rules separate the three sections so each reads as its
            // own block (more like a sectioned native sidebar).
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    pageRow(.playback)
                    Divider().padding(.horizontal, 12)
                    pageRow(.image)
                    Divider().padding(.horizontal, 12)
                    pageRow(.capture)
                }
                .padding(.vertical, 8)
                .animation(.snappy(duration: 0.22), value: page)
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
            // Indented to read as a setting nested under the detector picker.
            .padding(.leading, 16)
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
                        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                    Text(rowPage.title)
                        .fontWeight(isActive ? .semibold : .regular)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
                // Active mode = a subtle accent-tinted rounded selection
                // (the native-sidebar idiom), replacing the old accent dot.
                .background {
                    if isActive {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.accentColor.opacity(0.15))
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(disabled)

            if isActive && !disabled {
                expandedContent(for: rowPage)
                    .padding(.leading, 28)
                    .padding(.trailing, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
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
        // A modest, content-width bordered button — it's a utility action, not
        // the hero of the panel, so it shouldn't shout.
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
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
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)

        if recents.isEmpty {
            Text(emptyHint)
                .font(.callout)
                .foregroundStyle(.tertiary)
        } else {
            ForEach(recents, id: \.self) { url in
                Button {
                    onPick(url)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: systemImage)
                            .foregroundStyle(.secondary)
                            .font(.body)
                        Text(url.lastPathComponent)
                            .font(.body)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(url.path)
            }
        }
    }

    // MARK: - DATASET strip

    /// The bottom `DATASET` slot. On macOS it carries the working export
    /// controls ("Export now" in the header, an exported-frame count, the
    /// last-run summary, and a full-width "Reveal in Finder"). On iOS it's the
    /// read-only count only — that footer was always macOS-only (iOS exposes the
    /// Documents folder via Files.app instead).
    @ViewBuilder
    private var datasetStrip: some View {
        Divider()
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("DATASET")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                #if os(macOS)
                if isSweeping {
                    ProgressView()
                        .controlSize(.small)
                } else if let onExportNow {
                    Button {
                        Task { await onExportNow() }
                    } label: {
                        Label("Export now", systemImage: "square.and.arrow.down.on.square")
                    }
                    .controlSize(.small)
                    .disabled(isSweeping)
                    .help("Export all flagged frames to the dataset folder")
                }
                #endif
            }

            Text(exportedFrameCountText)
                .font(.caption2)
                .foregroundStyle(.tertiary)

            #if os(macOS)
            if let lastSummaryText {
                Text(lastSummaryText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }

            if let onRevealInFinder {
                Button(action: onRevealInFinder) {
                    Label("Reveal in Finder", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .help("Open the exported frames folder in Finder")
            }
            #endif
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
