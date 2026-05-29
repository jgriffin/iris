import CoreMedia
import SwiftUI

/// Thin built-in list of the current asset's flags. Each row shows a leading
/// bookmark accent, the timestamp (`mm:ss.SSS`), the captured detection count,
/// and the note when present. Tapping a row jumps the playhead to that flag
/// (``FlaggingModel/jump(to:)``); swipe-to-delete and a context-menu delete
/// remove it (``FlaggingModel/remove(_:)``). Empty state when no flags.
///
/// App owns placement (M4 doctrine): macOS hosts this in the existing right
/// inspector's "Flagged frames" section; iOS presents it in a sheet.
public struct FlaggedFramesList: View {

    /// The flagging brain — `currentFlags` (reactive), `jump`, `remove`.
    @Bindable public var model: FlaggingModel

    public init(model: FlaggingModel) {
        self.model = model
    }

    public var body: some View {
        if model.currentFlags.isEmpty {
            ContentUnavailableView {
                Label("No flagged frames", systemImage: "bookmark.slash")
            } description: {
                Text("Tap the bookmark on the scrubber to flag a frame for the dataset.")
            }
        } else {
            List {
                ForEach(model.currentFlags, id: \.ref) { flag in
                    row(flag)
                        .contentShape(Rectangle())
                        .onTapGesture { model.jump(to: flag) }
                        .contextMenu {
                            Button(role: .destructive) {
                                model.remove(flag)
                            } label: {
                                Label("Remove flag", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                model.remove(flag)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ flag: FrameFlag) -> some View {
        // No reason badge: a flag means "look again," not a verdict — showing
        // a "wrong"/"near-miss" label here would be false precision (M7·P3
        // reframe). The leading bookmark is a subtle accent echoing the
        // on-frame flag affordance; the reason still lives on the data model.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "bookmark.fill")
                .font(.caption)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(Self.timestamp(millis: flag.ref.ptsMillis))
                        .font(.body.monospacedDigit())
                    Spacer()
                    Text("\(flag.detections.count) det")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let note = flag.note, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Formatting

    /// Render integer milliseconds as `mm:ss.SSS`.
    static func timestamp(millis: Int64) -> String {
        let totalMillis = max(millis, 0)
        let ms = totalMillis % 1000
        let totalSeconds = totalMillis / 1000
        let seconds = totalSeconds % 60
        let minutes = totalSeconds / 60
        return String(format: "%02d:%02d.%03d", minutes, seconds, ms)
    }
}

#if DEBUG

#Preview("FlaggedFramesList · with flags") {
    let (model, _) = FlaggingModel.previewModel()
    return FlaggedFramesList(model: model)
        .frame(width: 320, height: 360)
}

#Preview("FlaggedFramesList · empty") {
    let (model, _) = FlaggingModel.previewModel(flags: [])
    return FlaggedFramesList(model: model)
        .frame(width: 320, height: 360)
}

#endif
