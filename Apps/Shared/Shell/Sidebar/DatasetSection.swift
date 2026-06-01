import SwiftUI

/// The bottom `DATASET` slot. On macOS it carries the working export controls
/// ("Export now" in the header accessory, an exported-frame count, the last-run
/// summary, and a full-width "Reveal in Finder"). On iOS it's the read-only
/// count only — that footer was always macOS-only (iOS exposes the Documents
/// folder via Files.app instead).
///
/// Built on the shared `SidebarSection("DATASET", accessory:)` container: the
/// export control rides in the header accessory; the count + summary + reveal
/// are the body. The macOS gating is preserved exactly as in the original.
struct DatasetSection: View {
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
        SidebarSection("DATASET", spacing: 6) {
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
        } content: {
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
    }
}

#if DEBUG
#Preview("Idle · exported") {
    DatasetSection(
        exportedFrameCountText: "12 frames exported",
        isSweeping: false,
        lastSummaryText: "Last sweep: 8 frames → ~/Datasets/iris (3.2 MB)",
        onExportNow: {},
        onRevealInFinder: {}
    )
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(width: 280)
}

#Preview("Sweeping") {
    DatasetSection(
        exportedFrameCountText: "12 frames exported",
        isSweeping: true,
        lastSummaryText: "Last sweep: 8 frames → ~/Datasets/iris (3.2 MB)",
        onExportNow: {},
        onRevealInFinder: {}
    )
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(width: 280)
}
#endif
