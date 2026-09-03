import AppKit
import Foundation
import PDFKit

/// A single document open in a tab. Owns the state the UI reads; the view's
/// coordinator registers itself as `controller` to receive imperative actions.
@Observable
final class OpenDocument: Identifiable {
    let id = UUID()
    let url: URL
    let kind: DocKind

    var title: String
    var loadError: String?

    /// Markdown source. Replaced on live reload; `revision` signals the view.
    var markdownText: String = ""
    var revision: Int = 0

    var outline: [OutlineItem] = []
    var activeOutlineID: String?

    var pageCount: Int = 0
    /// Zero-based.
    var currentPage: Int = 0
    var hasUnsavedChanges: Bool = false
    /// Flips once the PDF view is wired up, so the thumbnail sidebar can build.
    var pdfReady: Bool = false

    var searchQuery: String = ""
    var matchCount: Int = 0
    var matchIndex: Int = 0
    var isSearching: Bool = false

    @ObservationIgnored weak var controller: (any DocumentController)?
    @ObservationIgnored weak var pdfView: PDFView?
    @ObservationIgnored private var watcher: FileWatcher?

    init(url: URL, kind: DocKind) {
        self.url = url.standardizedFileURL
        self.kind = kind
        self.title = url.lastPathComponent
    }

    var directory: URL { url.deletingLastPathComponent() }

    /// Loads markdown content from disk. PDFs are loaded by their own view.
    func loadIfNeeded() {
        guard kind == .markdown else { return }
        do {
            markdownText = try TextFile.read(url)
            loadError = nil
        } catch {
            markdownText = ""
            loadError = error.localizedDescription
        }
    }

    /// Re-reads from disk and bumps `revision` so the renderer refreshes.
    func reloadFromDisk() {
        guard kind == .markdown else { return }
        let previous = markdownText
        loadIfNeeded()
        if markdownText != previous || loadError != nil { revision += 1 }
    }

    /// Starts watching the file so external edits appear without a keystroke.
    func startWatching() {
        guard kind == .markdown, watcher == nil else { return }
        watcher = FileWatcher(url: url) { [weak self] in
            self?.reloadFromDisk()
        }
    }

    func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    deinit { watcher?.cancel() }
}
