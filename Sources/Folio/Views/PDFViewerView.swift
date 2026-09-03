import AppKit
import PDFKit
import SwiftUI

/// Hosts a `PDFView`. PDFKit is the same renderer Preview uses, so text
/// selection, search and annotations behave the way macOS users expect.
struct PDFViewerView: NSViewRepresentable {
    let document: OpenDocument
    @Environment(Prefs.self) private var prefs
    @Environment(AppState.self) private var state

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document, state: state)
    }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = prefs.twoUp ? .twoUpContinuous : .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.pageShadowsEnabled = true
        pdfView.interpolationQuality = .high
        pdfView.backgroundColor = .underPageBackgroundColor

        context.coordinator.attach(to: pdfView)
        document.controller = context.coordinator
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        let wanted: PDFDisplayMode = prefs.twoUp ? .twoUpContinuous : .singlePageContinuous
        if pdfView.displayMode != wanted { pdfView.displayMode = wanted }
    }

    static func dismantleNSView(_ pdfView: PDFView, coordinator: Coordinator) {
        coordinator.detach()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, DocumentController {
        private let document: OpenDocument
        private let state: AppState
        private weak var pdfView: PDFView?
        private var pdfDocument: PDFDocument?

        private var matches: [PDFSelection] = []
        private var searchToken = 0
        private var observers: [NSObjectProtocol] = []

        var isEditable: Bool { true }

        init(document: OpenDocument, state: AppState) {
            self.document = document
            self.state = state
        }

        // MARK: Lifecycle

        func attach(to pdfView: PDFView) {
            self.pdfView = pdfView
            document.pdfView = pdfView

            let center = NotificationCenter.default
            observers.append(center.addObserver(
                forName: .PDFViewPageChanged, object: pdfView, queue: .main
            ) { [weak self] _ in self?.pageChanged() })

            load()
        }

        func detach() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            if let index = pdfView?.currentPage.flatMap({ pdfDocument?.index(for: $0) }) {
                Prefs.shared.setLastPage(index, for: document.url)
            }
            pdfView = nil
            document.pdfView = nil
        }

        deinit { detach() }

        private func load() {
            let url = document.url
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let loaded = PDFDocument(url: url)
                DispatchQueue.main.async {
                    guard let self, let pdfView = self.pdfView else { return }
                    guard let loaded else {
                        self.document.loadError =
                            "This file could not be opened as a PDF. It may be damaged or encrypted."
                        return
                    }
                    if loaded.isLocked {
                        self.promptForPassword(loaded)
                    }
                    self.pdfDocument = loaded
                    pdfView.document = loaded
                    self.document.pageCount = loaded.pageCount
                    self.document.loadError = loaded.isLocked
                        ? "This PDF is password protected."
                        : nil
                    self.buildOutline(from: loaded)
                    self.document.pdfReady = true
                    self.restoreReadingPosition()
                }
            }
        }

        private func promptForPassword(_ pdf: PDFDocument) {
            let alert = NSAlert()
            alert.messageText = "“\(document.title)” is password protected"
            alert.informativeText = "Enter the password to open this document."
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            alert.accessoryView = field
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if !pdf.unlock(withPassword: field.stringValue) {
                state.status = "Incorrect password"
            }
        }

        private func restoreReadingPosition() {
            guard let pdfView, let pdfDocument,
                  let last = Prefs.shared.lastPage(for: document.url),
                  last > 0, last < pdfDocument.pageCount,
                  let page = pdfDocument.page(at: last)
            else { return }
            // Layout has to settle before `go(to:)` lands on the right page.
            DispatchQueue.main.async {
                pdfView.go(to: page)
                self.state.status = "Resumed on page \(last + 1)"
            }
        }

        private func pageChanged() {
            guard let pdfView, let pdfDocument, let page = pdfView.currentPage else { return }
            let index = pdfDocument.index(for: page)
            document.currentPage = index
            Prefs.shared.setLastPage(index, for: document.url)
        }

        // MARK: Outline

        private func buildOutline(from pdf: PDFDocument) {
            var items: [OutlineItem] = []
            if let root = pdf.outlineRoot {
                flatten(root, level: 1, in: pdf, into: &items)
            }
            if items.isEmpty {
                // No embedded bookmarks: fall back to a page list, which is
                // still a faster way around a long scan than scrolling.
                items = (0..<pdf.pageCount).map { index in
                    let label = pdf.page(at: index)?.label ?? String(index + 1)
                    return OutlineItem(
                        id: "page-\(index)",
                        title: "Page \(label)",
                        level: 1,
                        pageIndex: index
                    )
                }
            }
            document.outline = items
        }

        private func flatten(
            _ node: PDFOutline,
            level: Int,
            in pdf: PDFDocument,
            into items: inout [OutlineItem]
        ) {
            guard level < 12 else { return }
            for position in 0..<node.numberOfChildren {
                guard let child = node.child(at: position) else { continue }
                var pageIndex: Int?
                if let page = child.destination?.page {
                    pageIndex = pdf.index(for: page)
                } else if let action = child.action as? PDFActionGoTo,
                          let page = action.destination.page {
                    pageIndex = pdf.index(for: page)
                }
                items.append(OutlineItem(
                    id: "outline-\(items.count)",
                    title: (child.label ?? "Untitled").trimmingCharacters(in: .whitespacesAndNewlines),
                    level: level,
                    pageIndex: pageIndex
                ))
                flatten(child, level: level + 1, in: pdf, into: &items)
            }
        }

        // MARK: Search

        private func search(_ query: String) {
            guard let pdfDocument, !query.isEmpty else {
                clearSearch()
                return
            }
            searchToken += 1
            let token = searchToken
            document.isSearching = true

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let found = pdfDocument.findString(query, withOptions: [.caseInsensitive])
                DispatchQueue.main.async {
                    guard let self, token == self.searchToken else { return }
                    self.document.isSearching = false
                    self.matches = found
                    self.document.matchCount = found.count
                    self.document.matchIndex = found.isEmpty ? 0 : 1

                    for selection in found {
                        selection.color = NSColor.systemYellow.withAlphaComponent(0.42)
                    }
                    self.pdfView?.highlightedSelections = found.isEmpty ? nil : found
                    if !found.isEmpty { self.go(toMatch: 0) }
                }
            }
        }

        private func clearSearch() {
            searchToken += 1
            matches = []
            document.matchCount = 0
            document.matchIndex = 0
            document.isSearching = false
            pdfView?.highlightedSelections = nil
            pdfView?.setCurrentSelection(nil, animate: false)
        }

        private func go(toMatch index: Int) {
            guard let pdfView, matches.indices.contains(index) else { return }
            let selection = matches[index]
            document.matchIndex = index + 1
            pdfView.setCurrentSelection(selection, animate: true)
            pdfView.go(to: selection)
        }

        private func stepMatch(by delta: Int) {
            guard !matches.isEmpty else { return }
            let current = max(0, document.matchIndex - 1)
            let next = (current + delta + matches.count) % matches.count
            go(toMatch: next)
        }

        // MARK: Annotations

        private func highlightSelection() {
            guard let pdfView, let selection = pdfView.currentSelection, !selection.string!.isEmpty else {
                state.status = "Select some text first"
                return
            }
            var added = 0
            for line in selection.selectionsByLine() {
                guard let page = line.pages.first else { continue }
                let bounds = line.bounds(for: page)
                guard bounds.width > 1, bounds.height > 1 else { continue }
                let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                annotation.color = NSColor.systemYellow
                page.addAnnotation(annotation)
                added += 1
            }
            guard added > 0 else { return }
            document.hasUnsavedChanges = true
            pdfView.setCurrentSelection(nil, animate: false)
            state.status = "Highlighted — press ⌘S to save"
        }

        // MARK: Saving

        private func save(to target: URL? = nil) {
            guard let pdfDocument else { return }
            let destination = target ?? document.url
            do {
                // Write beside the original and swap, so a failed write cannot
                // leave a truncated PDF where the document used to be.
                let temporary = destination
                    .deletingLastPathComponent()
                    .appendingPathComponent(".folio-\(UUID().uuidString).pdf")
                guard pdfDocument.write(to: temporary) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                } else {
                    try FileManager.default.moveItem(at: temporary, to: destination)
                }
                if target == nil { document.hasUnsavedChanges = false }
                state.status = "Saved \(destination.lastPathComponent)"
            } catch {
                let alert = NSAlert(error: error)
                alert.messageText = "Could not save \(destination.lastPathComponent)"
                alert.runModal()
            }
        }

        // MARK: DocumentController

        func perform(_ action: DocAction) {
            guard let pdfView else { return }
            switch action {
            case .zoomIn:
                pdfView.autoScales = false
                pdfView.zoomIn(nil)
            case .zoomOut:
                pdfView.autoScales = false
                pdfView.zoomOut(nil)
            case .zoomActualSize:
                pdfView.autoScales = false
                pdfView.scaleFactor = 1
            case .zoomToFit:
                pdfView.autoScales = true

            case .find(let query):
                search(query)
            case .findNext:
                stepMatch(by: 1)
            case .findPrevious:
                stepMatch(by: -1)
            case .endFind:
                clearSearch()

            case .goToPage(let index):
                if let page = pdfDocument?.page(at: index) { pdfView.go(to: page) }
            case .nextPage:
                pdfView.goToNextPage(nil)
            case .previousPage:
                pdfView.goToPreviousPage(nil)
            case .firstPage:
                pdfView.goToFirstPage(nil)
            case .lastPage:
                pdfView.goToLastPage(nil)

            case .rotateLeft:
                pdfView.currentPage?.rotation -= 90
                pdfView.layoutDocumentView()
            case .rotateRight:
                pdfView.currentPage?.rotation += 90
                pdfView.layoutDocumentView()
            case .setTwoUp(let enabled):
                pdfView.displayMode = enabled ? .twoUpContinuous : .singlePageContinuous

            case .copySelection:
                pdfView.copy(nil)
            case .selectAll:
                pdfView.selectAll(nil)
            case .highlightSelection:
                highlightSelection()

            case .save:
                save()
            case .exportPDF(let url):
                save(to: url)

            case .printDocument:
                let info = NSPrintInfo.shared
                if let operation = pdfDocument?.printOperation(
                    for: info, scalingMode: .pageScaleDownToFit, autoRotate: true
                ) {
                    operation.showsPrintPanel = true
                    operation.run()
                }

            case .revealInFinder:
                state.revealInFinder(document)

            case .reload:
                load()

            case .scrollTo, .themeChanged, .typographyChanged:
                break
            }
        }
    }
}

/// The page thumbnail rail, driven by whichever `PDFView` is showing.
struct PDFThumbnailRail: NSViewRepresentable {
    let document: OpenDocument

    func makeNSView(context: Context) -> PDFThumbnailView {
        let rail = PDFThumbnailView()
        rail.thumbnailSize = NSSize(width: 120, height: 156)
        rail.maximumNumberOfColumns = 1
        rail.backgroundColor = .clear
        rail.pdfView = document.pdfView
        return rail
    }

    func updateNSView(_ rail: PDFThumbnailView, context: Context) {
        if rail.pdfView !== document.pdfView { rail.pdfView = document.pdfView }
    }
}
