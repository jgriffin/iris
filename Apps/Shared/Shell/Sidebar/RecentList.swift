import SwiftUI

/// The `RECENT` list shown inside an expanded navigation row: a `RECENT` header
/// (routed through the shared `SidebarSectionHeader` style so it matches the
/// other section labels) followed by the recent entries — icon + filename,
/// truncated in the middle with the full path in a tooltip — or an empty hint.
struct RecentList: View {
    let recents: [URL]
    let systemImage: String
    let onPick: (URL) -> Void
    let emptyHint: String

    // NOTE: emits header + entries inside a `VStack(spacing: 6)` so the
    // header→entries gap matches the original, where `recentList` was a
    // @ViewBuilder helper splatted into `pageRow`'s `VStack(spacing: 6)`.
    // `SourcePicker` likewise places the open button and this list as
    // siblings at spacing 6, so the assembled column reads identically.
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SidebarSectionHeader("RECENT")
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
    }
}

#if DEBUG
#Preview("Populated") {
    VStack(alignment: .leading, spacing: 6) {
        RecentList(
            recents: PreviewFixtures.sampleVideoURLs,
            systemImage: "play.rectangle",
            onPick: { _ in },
            emptyHint: "Use Open Video… to pick a clip."
        )
    }
    .padding()
    .frame(width: 280)
}

#Preview("Empty") {
    VStack(alignment: .leading, spacing: 6) {
        RecentList(
            recents: [],
            systemImage: "play.rectangle",
            onPick: { _ in },
            emptyHint: "Use Open Video… to pick a clip."
        )
    }
    .padding()
    .frame(width: 280)
}
#endif
