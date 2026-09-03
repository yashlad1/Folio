import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: Binding(
                get: { state.sidebarMode },
                set: { state.sidebarMode = $0 }
            )) {
                ForEach(availableModes) { mode in
                    Image(systemName: mode.symbol)
                        .help(mode.label)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            Divider()

            switch state.sidebarMode {
            case .files: FileBrowser()
            case .outline: OutlinePane()
            case .thumbnails: ThumbnailPane()
            }
        }
    }

    private var availableModes: [SidebarMode] {
        state.current?.kind == .pdf
            ? SidebarMode.allCases
            : [.files, .outline]
    }
}

// MARK: - Files

private struct FileBrowser: View {
    @Environment(AppState.self) private var state
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            if let root = state.folderRoot {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    TextField("Filter", text: $filter)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                    if !filter.isEmpty {
                        Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 9)
                .frame(height: 26)

                Divider()

                List {
                    if filter.isEmpty {
                        FileRows(nodes: root.children ?? [], depth: 0)
                    } else {
                        ForEach(matches(in: root), id: \.id) { node in
                            FileRow(node: node, depth: 0)
                        }
                    }
                }
                .listStyle(.sidebar)

                Divider()

                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                    Text(root.name)
                        .font(.system(size: 10.5))
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                    Button { state.refreshFolder() } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .help("Rescan this folder")
                    Button { state.showOpenFolderPanel() } label: {
                        Image(systemName: "ellipsis").font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .help("Choose a different folder")
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .frame(height: 24)
            } else {
                VStack(spacing: 10) {
                    if state.isScanningFolder {
                        ProgressView().controlSize(.small)
                        Text("Scanning…").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("No folder open")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Open Folder…") { state.showOpenFolderPanel() }
                            .controlSize(.small)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private func matches(in root: FileNode) -> [FileNode] {
        var found: [FileNode] = []
        var stack = root.children ?? []
        let needle = filter.lowercased()
        while let node = stack.popLast() {
            if node.isDirectory {
                stack.append(contentsOf: node.children ?? [])
            } else if node.name.lowercased().contains(needle) {
                found.append(node)
            }
            if found.count >= 300 { break }
        }
        return found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

private struct FileRows: View {
    let nodes: [FileNode]
    let depth: Int

    var body: some View {
        ForEach(nodes, id: \.id) { node in
            if node.isDirectory {
                FolderRow(node: node, depth: depth)
            } else {
                FileRow(node: node, depth: depth)
            }
        }
    }
}

private struct FolderRow: View {
    let node: FileNode
    let depth: Int
    /// Top-level folders start open; deeper ones stay collapsed so a large
    /// vault does not arrive as a wall of text.
    @State private var isExpanded: Bool

    init(node: FileNode, depth: Int) {
        self.node = node
        self.depth = depth
        _isExpanded = State(initialValue: depth == 0 && (node.children?.count ?? 0) <= 12)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            FileRows(nodes: node.children ?? [], depth: depth + 1)
        } label: {
            Label {
                Text(node.name).font(.system(size: 11.5)).lineLimit(1)
            } icon: {
                Image(systemName: isExpanded ? "folder.fill" : "folder")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct FileRow: View {
    @Environment(AppState.self) private var state
    let node: FileNode
    let depth: Int

    private var isOpen: Bool { state.current?.url == node.url }

    var body: some View {
        Label {
            Text(node.name)
                .font(.system(size: 11.5, weight: isOpen ? .semibold : .regular))
                .lineLimit(1)
        } icon: {
            Image(systemName: DocKind.of(node.url)?.symbol ?? "doc")
                .foregroundStyle(isOpen ? Color.accentColor : .secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { state.open(node.url) }
        .help(node.url.path)
        .contextMenu {
            Button("Open") { state.open(node.url) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([node.url])
            }
        }
    }
}

// MARK: - Outline

private struct OutlinePane: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if let document = state.current {
            if document.outline.isEmpty {
                placeholder("No headings in this document")
            } else {
                List(document.outline) { item in
                    HStack(spacing: 0) {
                        Spacer().frame(width: CGFloat(min(item.level - 1, 5)) * 12)
                        Text(item.title)
                            .font(.system(
                                size: item.level <= 2 ? 12 : 11,
                                weight: item.level == 1 ? .semibold : .regular
                            ))
                            .lineLimit(2)
                            .foregroundStyle(isActive(item, in: document) ? Color.accentColor : .primary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { jump(to: item) }
                }
                .listStyle(.sidebar)
            }
        } else {
            placeholder("Open a document to see its outline")
        }
    }

    private func isActive(_ item: OutlineItem, in document: OpenDocument) -> Bool {
        switch document.kind {
        case .markdown: return item.anchor == document.activeOutlineID
        case .pdf: return item.pageIndex == document.currentPage
        }
    }

    private func jump(to item: OutlineItem) {
        if let anchor = item.anchor {
            state.send(.scrollTo(anchor: anchor))
        } else if let page = item.pageIndex {
            state.send(.goToPage(page))
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding()
            .frame(maxHeight: .infinity)
    }
}

// MARK: - Thumbnails

private struct ThumbnailPane: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if let document = state.current, document.kind == .pdf, document.pdfReady {
            PDFThumbnailRail(document: document)
        } else {
            Text("Page thumbnails appear here for PDFs")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxHeight: .infinity)
        }
    }
}
