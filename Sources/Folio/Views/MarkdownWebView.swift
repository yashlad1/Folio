import AppKit
import SwiftUI
import WebKit

/// Hosts the markdown renderer. All parsing and layout happens in the web
/// view; this type only moves content in and messages out.
struct MarkdownWebView: NSViewRepresentable {
    let document: OpenDocument
    @Environment(Prefs.self) private var prefs
    @Environment(AppState.self) private var state

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document, state: state)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(FolioSchemeHandler(), forURLScheme: FolioSchemeHandler.scheme)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "folio")
        configuration.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = true
        webView.allowsBackForwardNavigationGestures = false
        webView.setValue(false, forKey: "allowsLinkPreview")
        if #available(macOS 13.3, *) { webView.isInspectable = true }

        context.coordinator.webView = webView
        document.controller = context.coordinator

        // Relative images resolve only inside the document's own folder.
        FolioSchemeHandler.allow(directory: document.directory)

        webView.load(URLRequest(url: FolioSchemeHandler.indexURL))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.apply(
            prefs: prefs,
            isDark: webView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        )
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: "folio")
        webView.navigationDelegate = nil
        coordinator.webView = nil
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, DocumentController {
        weak var webView: WKWebView?
        private let document: OpenDocument
        private let state: AppState

        private var isReady = false
        private var renderedRevision = -1
        private var appliedTypography: String?
        private var appliedTheme: String?
        private var pendingDark: Bool?

        var isEditable: Bool { false }

        init(document: OpenDocument, state: AppState) {
            self.document = document
            self.state = state
        }

        // MARK: Pushing state into the page

        func apply(prefs: Prefs, isDark: Bool) {
            pendingDark = isDark
            guard isReady else { return }

            let theme = isDark ? "dark" : "light"
            if appliedTheme != theme {
                appliedTheme = theme
                evaluate("window.folio.setTheme('\(theme)')")
            }

            let typography = "\(prefs.fontSize)|\(prefs.readingFont.rawValue)|\(prefs.wideContent)|\(prefs.codeLineNumbers)"
            if appliedTypography != typography {
                appliedTypography = typography
                let payload: [String: Any] = [
                    "fontSize": prefs.fontSize,
                    "family": prefs.readingFont.rawValue,
                    "wide": prefs.wideContent,
                    "lineNumbers": prefs.codeLineNumbers,
                ]
                evaluate("window.folio.setTypography(\(json(payload)))")
            }

            if renderedRevision != document.revision {
                let preserveScroll = renderedRevision >= 0
                renderedRevision = document.revision
                pushContent(preserveScroll: preserveScroll)
            }
        }

        private func pushContent(preserveScroll: Bool) {
            let payload: [String: Any] = [
                "markdown": document.markdownText,
                "docDir": document.directory.path,
                "ext": document.url.pathExtension.lowercased(),
                "preserveScroll": preserveScroll,
            ]
            evaluate("window.folio.render(\(json(payload)))")
        }

        private func json(_ value: Any) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: []),
                  let text = String(data: data, encoding: .utf8)
            else { return "{}" }
            return text
        }

        private func evaluate(_ script: String) {
            webView?.evaluateJavaScript(script) { _, error in
                if let error, (error as NSError).code != WKError.javaScriptResultTypeIsUnsupported.rawValue {
                    NSLog("Folio markdown script error: \(error.localizedDescription)")
                }
            }
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isReady = true
            appliedTheme = nil
            appliedTypography = nil
            renderedRevision = -1
            apply(prefs: Prefs.shared, isDark: pendingDark ?? false)
        }

        /// The page never navigates. Anything that tries is a link the app owns.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if url == FolioSchemeHandler.indexURL || navigationAction.navigationType == .other,
               url.scheme == FolioSchemeHandler.scheme {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            if url.scheme == "http" || url.scheme == "https" || url.scheme == "mailto" {
                NSWorkspace.shared.open(url)
            }
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            document.loadError = "Renderer failed to load: \(error.localizedDescription)"
        }

        // MARK: WKScriptMessageHandler

        func userContentController(
            _ controller: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String
            else { return }

            switch type {
            case "outline":
                let raw = body["items"] as? [[String: Any]] ?? []
                document.outline = raw.compactMap { entry in
                    guard let id = entry["id"] as? String,
                          let title = entry["title"] as? String,
                          let level = entry["level"] as? Int
                    else { return nil }
                    return OutlineItem(id: id, title: title, level: level, anchor: id)
                }

            case "active":
                document.activeOutlineID = body["id"] as? String

            case "link":
                if let href = body["href"] as? String {
                    state.followLink(href, from: document)
                }

            case "ready":
                isReady = true

            default:
                break
            }
        }

        // MARK: DocumentController

        func perform(_ action: DocAction) {
            switch action {
            case .zoomIn: Prefs.shared.zoomText(by: 1)
            case .zoomOut: Prefs.shared.zoomText(by: -1)
            case .zoomActualSize, .zoomToFit: Prefs.shared.resetTextZoom()

            case .find(let query):
                find(query, forward: true)
            case .findNext:
                find(document.searchQuery, forward: true)
            case .findPrevious:
                find(document.searchQuery, forward: false)
            case .endFind:
                webView?.evaluateJavaScript("window.getSelection().removeAllRanges()")

            case .scrollTo(let anchor):
                evaluate("window.folio.scrollTo('\(anchor.replacingOccurrences(of: "'", with: "\\'"))')")

            case .selectAll:
                webView?.evaluateJavaScript("document.execCommand('selectAll')")
            case .copySelection:
                webView?.evaluateJavaScript("document.execCommand('copy')")

            case .reload:
                document.reloadFromDisk()

            case .themeChanged, .typographyChanged:
                appliedTheme = nil
                appliedTypography = nil
                apply(prefs: Prefs.shared, isDark: pendingDark ?? false)

            case .exportPDF(let url):
                exportPDF(to: url)
            case .printDocument:
                printDocument()

            case .revealInFinder:
                state.revealInFinder(document)

            default:
                break
            }
        }

        private func find(_ query: String, forward: Bool) {
            guard let webView, !query.isEmpty else {
                document.matchCount = 0
                return
            }
            let configuration = WKFindConfiguration()
            configuration.backwards = !forward
            configuration.caseSensitive = false
            configuration.wraps = true
            webView.find(query, configuration: configuration) { [weak self] result in
                // WKFindResult reports only whether a match exists, not how many.
                self?.document.matchCount = result.matchFound ? -1 : 0
            }
        }

        // MARK: Printing

        /// Builds print settings shared by Print and Export as PDF, so a saved
        /// file matches what the printer would produce.
        private func printInfo() -> NSPrintInfo {
            let info = NSPrintInfo()
            info.horizontalPagination = .fit
            info.verticalPagination = .automatic
            info.isHorizontallyCentered = false
            info.isVerticallyCentered = false
            info.topMargin = 40
            info.bottomMargin = 40
            info.leftMargin = 40
            info.rightMargin = 40
            return info
        }

        private func exportPDF(to url: URL) {
            guard let webView else { return }
            evaluate("window.folio.beginExport()")
            // Give the page one frame to relayout in export mode.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self else { return }
                let info = self.printInfo()
                info.jobDisposition = .save
                info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url as NSURL

                let operation = webView.printOperation(with: info)
                operation.showsPrintPanel = false
                operation.showsProgressPanel = true
                operation.view?.frame = NSRect(x: 0, y: 0, width: 600, height: 800)
                operation.run()

                self.evaluate("window.folio.endExport()")
                self.state.status = "Exported to \(url.lastPathComponent)"
            }
        }

        private func printDocument() {
            guard let webView else { return }
            evaluate("window.folio.beginExport()")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self else { return }
                let operation = webView.printOperation(with: self.printInfo())
                operation.showsPrintPanel = true
                operation.showsProgressPanel = true
                if let window = webView.window {
                    operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
                } else {
                    operation.run()
                }
                self.evaluate("window.folio.endExport()")
            }
        }
    }
}
