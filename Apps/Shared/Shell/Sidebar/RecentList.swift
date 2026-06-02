import SwiftUI

/// The recent-entries list shown inside an active mode section's body: the
/// recent files — a file glyph + the filename, truncated in the middle with the
/// full path in a tooltip — or an empty hint. The "RECENT" caption was dropped
/// in the M9·P6·4 redesign: the rows live visibly inside the selected section's
/// band, so the label is redundant.
struct RecentList: View {
    let recents: [URL]
    let systemImage: String
    let onPick: (URL) -> Void
    let emptyHint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if recents.isEmpty {
                Text(emptyHint)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 28)   // align under where filenames sit
            } else {
                ForEach(recents, id: \.self) { url in
                    Button {
                        onPick(url)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: systemImage)
                                .frame(width: 20)
                                .foregroundStyle(.secondary)
                            Text(url.lastPathComponent)
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
    }
}

#if DEBUG
#Preview("Populated") {
    RecentList(
        recents: PreviewFixtures.sampleVideoURLs,
        systemImage: "film",
        onPick: { _ in },
        emptyHint: "No recent videos"
    )
    .padding()
    .frame(width: 280)
}

#Preview("Empty") {
    RecentList(
        recents: [],
        systemImage: "film",
        onPick: { _ in },
        emptyHint: "No recent videos"
    )
    .padding()
    .frame(width: 280)
}
#endif
