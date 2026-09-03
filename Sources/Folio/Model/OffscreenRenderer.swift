import AppKit
import Foundation
import WebKit

/// Produces PDFs from documents that are not open in a tab.
///
/// Markdown is routed through the same renderer the app displays, so an
/// exported file gets the real KaTeX, Mermaid and syntax highlighting rather
/// than a second, lesser implementation. That means a live `WKWebView`, which
/// in turn means a window: WebKit will not lay out or paint a view that has no
/// window, so each conversion hosts one for its duration.
///
/// Pagination is done by hand rather than through `NSPrintOperation`. That API
/// hands the job to `WKPrintingView`, which fetches the rendered page over IPC
/// and, with no modal run loop to service the reply, draws its blank *preview*
/// instead — silently producing empty PDFs, or spooling pages without bound.
/// `createPDF` is asynchronous and has no such requirement, so the content is
/// captured one page-sized slice at a time and the slices are stitched onto
/// paper here.
///
/// Conversion never touches the network. Every asset the renderer needs is
/// vendored into the bundle, and the web view is fitted with a content blocker
/// that refuses any scheme other than the local ones — otherwise a document
/// containing `<img src="https://…">` would quietly phone out (and could
/// exfiltrate through the query string) the moment it was converted.
@MainActor
final class OffscreenRenderer {
    static let shared = OffscreenRenderer()

    private init() {}

    /// Waits for webfonts and images, which land after `didFinish`.
    private static let settleScript = """
        try { await document.fonts.ready; } catch (error) { /* older WebKit */ }
        await Promise.all([...document.images].map((image) => (
            image.complete ? null : new Promise((done) => {
                image.addEventListener('load', done, { once: true });
                image.addEventListener('error', done, { once: true });
            })
        )));
        return true;
        """

    /// Block everything, then re-admit the local schemes. Later rules win, so
    /// the effect is an allowlist: folio:// bundle assets, file:// neighbours,
    /// and the inline forms. http/https/ws never load.
    ///
    /// Each scheme needs its own rule — WebKit's content-blocker regex engine
    /// rejects alternation, so a single `^(folio|file|…):` pattern fails to
    /// compile and would leave the guard silently disarmed.
    /// Internal rather than private so the test suite can prove it compiles;
    /// a malformed rule list disarms the guard silently.
    static let blockRules: String = {
        let allowed = ["folio", "file", "data", "blob", "about"]
        let admit = allowed.map {
            #"{ "trigger": { "url-filter": "^\#($0):" }, "action": { "type": "ignore-previous-rules" } }"#
        }
        let block = #"{ "trigger": { "url-filter": ".*" }, "action": { "type": "block" } }"#
        return "[\n" + ([block] + admit).joined(separator: ",\n") + "\n]"
    }()

    private var compiledBlocker: WKContentRuleList?

    /// Compiled once per launch and reused; compilation is not free.
    private func networkBlocker() async throws -> WKContentRuleList {
        if let compiledBlocker { return compiledBlocker }
        let store = WKContentRuleListStore.default()
        let list: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
            store?.compileContentRuleList(
                forIdentifier: "folio-offline-conversion",
                encodedContentRuleList: Self.blockRules
            ) { list, error in
                if let list {
                    continuation.resume(returning: list)
                } else {
                    continuation.resume(
                        throwing: error ?? ConversionError.renderFailed("Could not arm the offline guard")
                    )
                }
            }
        }
        compiledBlocker = list
        return list
    }

    // MARK: Entry points

    func pdf(
        fromMarkdown text: String,
        extension ext: String,
        documentDirectory: URL,
        to destination: URL
    ) async throws {
        // Relative images in the document resolve only inside its own folder.
        FolioSchemeHandler.allow(directory: documentDirectory)

        let session = Session(usesFolioScheme: true, blocker: try await networkBlocker())
        defer { session.close() }

        try await session.load { $0.load(URLRequest(url: FolioSchemeHandler.indexURL)) }

        let prefs = Prefs.shared
        let payload: [String: Any] = [
            "markdown": text,
            "docDir": documentDirectory.path,
            "ext": ext.isEmpty ? "md" : ext,
            "preserveScroll": false,
        ]
        let typography: [String: Any] = [
            "fontSize": prefs.fontSize,
            "family": prefs.readingFont.rawValue,
            "wide": prefs.wideContent,
            "lineNumbers": prefs.codeLineNumbers,
        ]

        // beginExport() first: it forces the light theme, and switching theme
        // afterwards would re-render every diagram for nothing.
        do {
            _ = try await session.webView.callAsyncJavaScript(
                """
                window.folio.setTypography(typography);
                window.folio.beginExport();
                return await window.folio.renderAndSettle(payload);
                """,
                arguments: ["payload": payload, "typography": typography],
                contentWorld: .page
            )
        } catch {
            throw ConversionError.renderFailed("Could not render the document: \(error.localizedDescription)")
        }

        try await writePaginatedPDF(session.webView, to: destination)
    }

    func pdf(fromHTMLFile source: URL, to destination: URL) async throws {
        let session = Session(usesFolioScheme: false, blocker: try await networkBlocker())
        defer { session.close() }

        // A plain file load, so stylesheets and images beside the page resolve.
        try await session.load {
            $0.loadFileURL(source, allowingReadAccessTo: source.deletingLastPathComponent())
        }
        // Best effort: a page with no images or broken JS should still export.
        _ = try? await session.webView.callAsyncJavaScript(
            Self.settleScript, arguments: [:], contentWorld: .page
        )

        try await writePaginatedPDF(session.webView, to: destination)
    }

    // MARK: Output

    /// Refuses to spool a runaway document rather than filling the disk.
    private static let pageLimit = 2000

    private func writePaginatedPDF(_ webView: WKWebView, to destination: URL) async throws {
        let width = webView.frame.width
        let measured = try? await webView.callAsyncJavaScript(
            """
            const root = document.documentElement;
            return Math.ceil(Math.max(root.scrollHeight, document.body.scrollHeight));
            """,
            arguments: [:],
            contentWorld: .page
        )
        let contentHeight = CGFloat((measured as? NSNumber)?.doubleValue ?? 0)
        guard contentHeight > 0, width > 0 else {
            throw ConversionError.renderFailed("The document rendered empty")
        }

        let info = PrintSetup.info()
        let paper = info.paperSize
        let printableWidth = paper.width - info.leftMargin - info.rightMargin
        let printableHeight = paper.height - info.topMargin - info.bottomMargin

        // The page is laid out at `width` CSS points and scaled down to the
        // printable column, which is what pagination `.fit` would have done.
        let scale = printableWidth / width
        let sliceHeight = printableHeight / scale

        let pageCount = max(Int((contentHeight / sliceHeight).rounded(.up)), 1)
        guard pageCount <= Self.pageLimit else {
            throw ConversionError.renderFailed("The document is too long to convert (\(pageCount) pages)")
        }

        var slices: [Data] = []
        for index in 0..<pageCount {
            let top = CGFloat(index) * sliceHeight
            let height = min(sliceHeight, contentHeight - top)
            guard height > 1 else { break }

            let configuration = WKPDFConfiguration()
            configuration.rect = CGRect(x: 0, y: top, width: width, height: height)
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                webView.createPDF(configuration: configuration) { continuation.resume(with: $0) }
            }
            slices.append(data)
        }

        try stitch(slices, scale: scale, info: info, to: destination)
    }

    /// Draws each captured slice onto its own sheet of paper.
    private func stitch(_ slices: [Data], scale: CGFloat, info: NSPrintInfo, to destination: URL) throws {
        guard !slices.isEmpty else { throw ConversionError.writeFailed(destination) }

        let paper = info.paperSize
        var mediaBox = CGRect(origin: .zero, size: paper)
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { throw ConversionError.writeFailed(destination) }

        let printableHeight = paper.height - info.topMargin - info.bottomMargin

        for slice in slices {
            guard let provider = CGDataProvider(data: slice as CFData),
                  let document = CGPDFDocument(provider),
                  let page = document.page(at: 1)
            else { continue }

            let box = page.getBoxRect(.mediaBox)
            context.beginPDFPage(nil)
            context.saveGState()
            // A short final slice hangs from the top margin rather than
            // floating up off the foot of the page.
            let drawnHeight = box.height * scale
            context.translateBy(
                x: info.leftMargin,
                y: info.bottomMargin + (printableHeight - drawnHeight)
            )
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -box.origin.x, y: -box.origin.y)
            context.drawPDFPage(page)
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()

        guard output.length > 0 else { throw ConversionError.writeFailed(destination) }
        try output.write(to: destination, options: .atomic)
    }

    // MARK: - Session

    /// One off-screen web view and the window keeping it alive.
    @MainActor
    private final class Session: NSObject, WKNavigationDelegate {
        let webView: WKWebView
        private let window: NSWindow
        private var pending: ((Error?) -> Void)?

        init(usesFolioScheme: Bool, blocker: WKContentRuleList) {
            let configuration = WKWebViewConfiguration()
            if usesFolioScheme {
                configuration.setURLSchemeHandler(
                    FolioSchemeHandler(), forURLScheme: FolioSchemeHandler.scheme
                )
            }
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
            // Nothing from a conversion is worth persisting to a cache on disk.
            configuration.websiteDataStore = .nonPersistent()
            configuration.userContentController.add(blocker)

            let frame = NSRect(x: 0, y: 0, width: 800, height: 1000)
            webView = WKWebView(frame: frame, configuration: configuration)

            let origin = NSScreen.main?.visibleFrame.origin ?? .zero
            window = NSWindow(
                contentRect: NSRect(origin: origin, size: frame.size),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.level = .init(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            window.contentView = webView

            super.init()
            webView.navigationDelegate = self
            window.orderBack(nil)
            // Force a layout pass before anything asks the view to paginate.
            webView.layoutSubtreeIfNeeded()
        }

        /// Runs `start` and resolves when the navigation finishes or times out.
        func load(timeout: TimeInterval = 30, _ start: (WKWebView) -> Void) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                var isSettled = false
                let finish: (Error?) -> Void = { [weak self] error in
                    guard !isSettled else { return }
                    isSettled = true
                    self?.pending = nil
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
                pending = finish
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                    finish(ConversionError.renderFailed("Timed out loading the renderer"))
                }
                start(webView)
            }
        }

        /// A second line of defence: even a top-level navigation to a remote
        /// URL is refused, so a redirect cannot walk the renderer off-device.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
            let local = ["folio", "file", "data", "blob", "about"]
            decisionHandler(local.contains(scheme) ? .allow : .cancel)
        }

        func close() {
            webView.navigationDelegate = nil
            window.contentView = nil
            window.orderOut(nil)
            window.close()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pending?(nil)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            pending?(error)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            pending?(error)
        }
    }
}
