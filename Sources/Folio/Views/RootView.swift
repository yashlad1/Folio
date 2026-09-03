import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(AppState.self) private var state
    @Environment(Prefs.self) private var prefs

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isDropTarget = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 260, max: 420)
        } detail: {
            detail
        }
        .navigationTitle(state.current?.title ?? "Folio")
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls { state.open(url) }
            return !urls.isEmpty
        } isTargeted: { isDropTarget = $0 }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: Binding(
            get: { state.isGoToPageVisible },
            set: { state.isGoToPageVisible = $0 }
        )) {
            GoToPageSheet()
        }
        .sheet(isPresented: Binding(
            get: { state.isConvertPresented },
            set: { state.isConvertPresented = $0 }
        )) {
            ConvertSheet(sources: state.conversionSources)
        }
        .onChange(of: prefs.theme) { state.broadcast(.themeChanged) }
        .onChange(of: prefs.fontSize) { state.broadcast(.typographyChanged) }
        .onChange(of: prefs.readingFont) { state.broadcast(.typographyChanged) }
        .onChange(of: prefs.wideContent) { state.broadcast(.typographyChanged) }
        .onChange(of: prefs.codeLineNumbers) { state.broadcast(.typographyChanged) }
        .onChange(of: prefs.twoUp) { state.send(.setTwoUp(prefs.twoUp)) }
        .onChange(of: state.current?.kind) { _, kind in
            if kind == .markdown, state.sidebarMode == .thumbnails { state.sidebarMode = .outline }
        }
    }

    private var subtitle: String {
        guard let document = state.current else { return "" }
        switch document.kind {
        case .pdf:
            guard document.pageCount > 0 else { return "" }
            return "Page \(document.currentPage + 1) of \(document.pageCount)"
        case .markdown:
            return document.directory.lastPathComponent
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 0) {
            if !state.tabs.isEmpty {
                TabStrip()
                Divider()
            }

            ZStack {
                if state.tabs.isEmpty {
                    EmptyStateView()
                } else {
                    // Every open tab stays mounted so switching back keeps the
                    // scroll position, PDF zoom and search highlights intact.
                    ForEach(state.tabs) { document in
                        documentView(document)
                            .opacity(document.id == state.selectedTabID ? 1 : 0)
                            .allowsHitTesting(document.id == state.selectedTabID)
                            .accessibilityHidden(document.id != state.selectedTabID)
                    }
                }
            }
            .overlay(alignment: .top) {
                if state.isFindBarVisible, state.current != nil {
                    FindBar().padding(10)
                }
            }

            StatusBar()
        }
    }

    @ViewBuilder
    private func documentView(_ document: OpenDocument) -> some View {
        if let error = document.loadError {
            DocumentErrorView(document: document, message: error)
        } else {
            switch document.kind {
            case .markdown:
                MarkdownWebView(document: document)
            case .pdf:
                PDFViewerView(document: document)
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                state.showOpenFilePanel()
            } label: {
                Label("Open", systemImage: "folder")
            }
            .help("Open a file or folder (⌘O)")
        }

        if let document = state.current {
            ToolbarItemGroup {
                Spacer()

                if document.kind == .pdf {
                    Button { state.send(.previousPage) } label: {
                        Label("Previous Page", systemImage: "chevron.up")
                    }
                    .help("Previous page")

                    Button { state.send(.nextPage) } label: {
                        Label("Next Page", systemImage: "chevron.down")
                    }
                    .help("Next page")

                    Button { state.isGoToPageVisible = true } label: {
                        Label("Go to Page", systemImage: "number")
                    }
                    .help("Go to page (⌘G)")

                    Divider()

                    Button { state.send(.highlightSelection) } label: {
                        Label("Highlight", systemImage: "highlighter")
                    }
                    .help("Highlight the selected text (⌘⇧H)")

                    Button { state.send(.rotateRight) } label: {
                        Label("Rotate", systemImage: "rotate.right")
                    }
                    .help("Rotate this page")

                    Toggle(isOn: Binding(
                        get: { prefs.twoUp },
                        set: { prefs.twoUp = $0 }
                    )) {
                        Label("Two Pages", systemImage: "book.pages")
                    }
                    .help("Show two pages side by side")
                } else {
                    Menu {
                        Picker("Typeface", selection: Binding(
                            get: { prefs.readingFont },
                            set: { prefs.readingFont = $0 }
                        )) {
                            ForEach(ReadingFont.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.inline)

                        Divider()

                        Toggle("Full Width", isOn: Binding(
                            get: { prefs.wideContent },
                            set: { prefs.wideContent = $0 }
                        ))
                        Toggle("Line Numbers in Code", isOn: Binding(
                            get: { prefs.codeLineNumbers },
                            set: { prefs.codeLineNumbers = $0 }
                        ))
                    } label: {
                        Label("Reading", systemImage: "textformat")
                    }
                    .help("Reading options")
                }

                Divider()

                Button { state.send(.zoomOut) } label: {
                    Label("Zoom Out", systemImage: "minus.magnifyingglass")
                }
                .help("Zoom out (⌘−)")

                Button { state.send(.zoomIn) } label: {
                    Label("Zoom In", systemImage: "plus.magnifyingglass")
                }
                .help("Zoom in (⌘+)")

                Button {
                    state.isFindBarVisible.toggle()
                } label: {
                    Label("Find", systemImage: "magnifyingglass")
                }
                .help("Find in document (⌘F)")

                Menu {
                    Button("Export as PDF…") { state.exportCurrentAsPDF() }
                    Button("Print…") { state.send(.printDocument) }
                    Divider()
                    Button("Reveal in Finder") { state.send(.revealInFinder) }
                    Button("Reload from Disk") { state.send(.reload) }
                    if document.kind == .pdf {
                        Divider()
                        Button("Save") { state.send(.save) }
                            .disabled(!document.hasUnsavedChanges)
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
    }
}

// MARK: - Status bar

private struct StatusBar: View {
    @Environment(AppState.self) private var state
    @Environment(Prefs.self) private var prefs

    var body: some View {
        HStack(spacing: 8) {
            if let message = state.status {
                Image(systemName: "info.circle")
                Text(message).lineLimit(1)
            } else if let document = state.current {
                Image(systemName: document.kind.symbol)
                Text(document.url.path)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
            }

            Spacer()

            if let document = state.current {
                if document.kind == .pdf, document.pageCount > 0 {
                    Text("\(document.currentPage + 1) / \(document.pageCount)")
                        .monospacedDigit()
                    if document.hasUnsavedChanges {
                        Text("Edited").foregroundStyle(.orange)
                    }
                } else if document.kind == .markdown {
                    Text("\(Int(prefs.fontSize)) pt").monospacedDigit()
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .task(id: state.status) {
            guard state.status != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            state.status = nil
        }
    }
}

// MARK: - Go to page

private struct GoToPageSheet: View {
    @Environment(AppState.self) private var state
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Go to Page").font(.headline)
            HStack {
                TextField("Page number", text: $text)
                    .frame(width: 120)
                    .onSubmit(go)
                if let document = state.current, document.pageCount > 0 {
                    Text("of \(document.pageCount)").foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { state.isGoToPageVisible = false }
                    .keyboardShortcut(.cancelAction)
                Button("Go", action: go)
                    .keyboardShortcut(.defaultAction)
                    .disabled(Int(text) == nil)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func go() {
        guard let page = Int(text), page >= 1 else { return }
        state.send(.goToPage(page - 1))
        state.isGoToPageVisible = false
    }
}

// MARK: - Load failure

private struct DocumentErrorView: View {
    @Environment(AppState.self) private var state
    let document: OpenDocument
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 38))
                .foregroundStyle(.orange)
            Text(document.title).font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack {
                Button("Try Again") { state.send(.reload) }
                Button("Reveal in Finder") { state.revealInFinder(document) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
