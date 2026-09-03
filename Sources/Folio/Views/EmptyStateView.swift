import SwiftUI

struct EmptyStateView: View {
    @Environment(AppState.self) private var state
    @State private var recents = Recents.shared

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 52, weight: .thin))
                    .foregroundStyle(.tertiary)
                Text("Folio")
                    .font(.system(size: 24, weight: .semibold))
                Text("Markdown and PDF, read locally.")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button {
                    state.showOpenFilePanel()
                } label: {
                    Label("Open File…", systemImage: "doc")
                        .frame(width: 120)
                }
                .keyboardShortcut("o")

                Button {
                    state.showOpenFolderPanel()
                } label: {
                    Label("Open Folder…", systemImage: "folder")
                        .frame(width: 120)
                }
            }
            .controlSize(.large)

            Text("or drag files here")
                .font(.caption)
                .foregroundStyle(.tertiary)

            if !recents.items.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("RECENT")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button("Clear") { recents.clear() }
                            .buttonStyle(.plain)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.bottom, 3)

                    ForEach(recents.items.prefix(8), id: \.path) { url in
                        RecentRow(url: url)
                    }
                }
                .frame(width: 380)
                .padding(14)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { recents.prune() }
    }
}

private struct RecentRow: View {
    @Environment(AppState.self) private var state
    let url: URL
    @State private var isHovering = false

    private var isFolder: Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: isFolder ? "folder" : (DocKind.of(url)?.symbol ?? "doc"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(url.lastPathComponent)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(url.deletingLastPathComponent().path)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(isHovering ? Color.accentColor.opacity(0.14) : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { state.open(url) }
        .onHover { isHovering = $0 }
        .help(url.path)
    }
}
