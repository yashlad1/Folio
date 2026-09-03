import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SidebarMode: String, CaseIterable, Identifiable {
    case files, outline, thumbnails

    var id: String { rawValue }

    var label: String {
        switch self {
        case .files: return "Files"
        case .outline: return "Outline"
        case .thumbnails: return "Pages"
        }
    }

    var symbol: String {
        switch self {
        case .files: return "folder"
        case .outline: return "list.bullet.indent"
        case .thumbnails: return "square.grid.2x2"
        }
    }
}

/// The single source of truth for the window: which documents are open, which
/// tab is selected, and what the sidebar is showing.
@Observable
final class AppState {
    static let shared = AppState()

    var tabs: [OpenDocument] = []
    var selectedTabID: UUID?
    var folderRoot: FileNode?
    var isScanningFolder = false

    var sidebarMode: SidebarMode = .files
    var isFindBarVisible = false
    var isGoToPageVisible = false
    var status: String?

    private init() {}

    var current: OpenDocument? {
        guard let id = selectedTabID else { return nil }
        return tabs.first { $0.id == id }
    }

    // MARK: Opening

    /// Opens a file or folder. Folders become the sidebar root; files become tabs.
    @discardableResult
    func open(_ url: URL) -> OpenDocument? {
        let target = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) else {
            status = "Not found: \(target.lastPathComponent)"
            Recents.shared.forget(target)
            return nil
        }

        if isDirectory.boolValue {
            openFolder(target)
            return nil
        }

        guard let kind = DocKind.of(target) else {
            status = "Folio cannot display .\(target.pathExtension) files"
            return nil
        }

        if let existing = tabs.first(where: { $0.url == target }) {
            selectedTabID = existing.id
            if existing.kind == .markdown { existing.reloadFromDisk() }
            return existing
        }

        let document = OpenDocument(url: target, kind: kind)
        document.loadIfNeeded()
        document.startWatching()
        tabs.append(document)
        selectedTabID = document.id
        Recents.shared.remember(target)

        // A lone file with no folder open: adopt its directory for the sidebar.
        if folderRoot == nil {
            openFolder(target.deletingLastPathComponent(), remember: false)
        }
        if sidebarMode == .thumbnails && kind == .markdown { sidebarMode = .outline }
        return document
    }

    func openFolder(_ url: URL, remember: Bool = true) {
        let target = url.standardizedFileURL
        if remember { Recents.shared.remember(target) }
        isScanningFolder = true
        DispatchQueue.global(qos: .userInitiated).async {
            let tree = FileTree.build(root: target)
            DispatchQueue.main.async {
                self.folderRoot = tree
                self.isScanningFolder = false
                if tree.children?.isEmpty ?? true {
                    self.status = "No markdown or PDF files in \(target.lastPathComponent)"
                }
            }
        }
    }

    func refreshFolder() {
        guard let root = folderRoot else { return }
        openFolder(root.url, remember: false)
    }

    // MARK: Panels

    func showOpenFilePanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "Choose markdown files, PDFs, or a folder"
        panel.prompt = "Open"
        if let root = folderRoot { panel.directoryURL = root.url }
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { open(url) }
    }

    func showOpenFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to browse"
        panel.prompt = "Open Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openFolder(url)
    }

    // MARK: Tabs

    func close(_ document: OpenDocument) {
        if document.hasUnsavedChanges, !confirmDiscard(document) { return }
        document.stopWatching()
        guard let index = tabs.firstIndex(where: { $0.id == document.id }) else { return }
        tabs.remove(at: index)
        if selectedTabID == document.id {
            selectedTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
        if tabs.isEmpty { isFindBarVisible = false }
    }

    func closeCurrent() {
        guard let document = current else { return }
        close(document)
    }

    func closeOthers(than document: OpenDocument) {
        for other in tabs where other.id != document.id { close(other) }
    }

    private func confirmDiscard(_ document: OpenDocument) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Save changes to \(document.title)?"
        alert.informativeText = "Your highlights and notes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            document.controller?.perform(.save)
            return true
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func selectTab(offset: Int) {
        guard !tabs.isEmpty else { return }
        let currentIndex = tabs.firstIndex { $0.id == selectedTabID } ?? 0
        let next = (currentIndex + offset + tabs.count) % tabs.count
        selectedTabID = tabs[next].id
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedTabID = tabs[index].id
    }

    // MARK: Actions routed to the active document

    func send(_ action: DocAction) {
        current?.controller?.perform(action)
    }

    func broadcast(_ action: DocAction) {
        for tab in tabs { tab.controller?.perform(action) }
    }

    /// Resolves a link clicked inside rendered markdown.
    func followLink(_ raw: String, from document: OpenDocument) {
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") || raw.hasPrefix("mailto:") {
            if let url = URL(string: raw) { NSWorkspace.shared.open(url) }
            return
        }

        // Wiki-style link: search the open folder, then the document's directory.
        if raw.hasPrefix("wiki:") {
            let name = String(raw.dropFirst("wiki:".count))
            if let root = folderRoot, let found = FileTree.findByBasename(name, in: root) {
                open(found)
                return
            }
            for ext in ["md", "markdown", "txt", "pdf"] {
                let candidate = document.directory.appendingPathComponent("\(name).\(ext)")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    open(candidate)
                    return
                }
            }
            status = "No document named “\(name)”"
            return
        }

        let path = raw.removingPercentEncoding ?? raw
        let resolved = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : document.directory.appendingPathComponent(path)

        if DocKind.of(resolved) != nil {
            open(resolved)
        } else if FileManager.default.fileExists(atPath: resolved.path) {
            NSWorkspace.shared.open(resolved)
        } else {
            status = "Cannot open \(resolved.lastPathComponent)"
        }
    }

    func revealInFinder(_ document: OpenDocument) {
        NSWorkspace.shared.activateFileViewerSelecting([document.url])
    }

    // MARK: Export

    func exportCurrentAsPDF() {
        guard let document = current else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = document.url.deletingPathExtension().lastPathComponent + ".pdf"
        panel.allowedContentTypes = [.pdf]
        panel.message = "Export the rendered document as a PDF"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        document.controller?.perform(.exportPDF(url))
    }

    // MARK: Conversion

    var conversionSources: [URL] = []
    var isConvertPresented = false

    /// Opens the converter over a specific set of files.
    func showConverter(for urls: [URL]) {
        conversionSources = urls.map(\.standardizedFileURL)
        isConvertPresented = true
    }

    /// Opens the converter on the current document, or empty so the sheet
    /// prompts for files.
    func showConverter() {
        showConverter(for: current.map { [$0.url] } ?? [])
    }
}
