import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves the `folio://` scheme to the markdown web view.
///
/// Two hosts exist:
///  - `folio://app/<path>` — the bundled renderer (HTML, CSS, vendored JS).
///  - `folio://doc/?p=<absolute path>` — a file sitting next to an open
///    document, so relative image references resolve.
///
/// A custom scheme is used rather than `file://` because `loadFileURL` grants
/// read access to exactly one directory tree, and the renderer needs both its
/// own assets and the document's folder. Serving it here also means every read
/// passes the allowlist below instead of handing WebKit the whole disk.
final class FolioSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "folio"

    /// Directories whose files may be served as `folio://doc`.
    private static var allowedRoots: Set<String> = []
    private static let lock = NSLock()

    static func allow(directory url: URL) {
        lock.lock()
        defer { lock.unlock() }
        allowedRoots.insert(url.standardizedFileURL.resolvingSymlinksInPath().path)
    }

    private static func isAllowed(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return allowedRoots.contains { root in
            path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }

    /// The bundled `web` directory, or the source tree when run via `swift run`.
    static let webRoot: URL = {
        if let override = ProcessInfo.processInfo.environment["FOLIO_WEB_ROOT"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("web", isDirectory: true)
            if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        }
        // Development fallback: <package>/Web relative to the executable.
        return Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Web", isDirectory: true)
    }()

    static var indexURL: URL { URL(string: "\(scheme)://app/index.html")! }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(Failure.badRequest)
            return
        }

        do {
            let file = try resolve(url)
            let data = try Data(contentsOf: file)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": Self.mimeType(for: file),
                    "Content-Length": String(data.count),
                    "Cache-Control": "no-cache",
                    "Access-Control-Allow-Origin": "*",
                ]
            )!
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
        } catch {
            task.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    // MARK: Resolution

    private enum Failure: LocalizedError {
        case badRequest
        case forbidden(String)
        case notFound(String)

        var errorDescription: String? {
            switch self {
            case .badRequest: return "Malformed folio:// request"
            case .forbidden(let path): return "Access denied: \(path)"
            case .notFound(let path): return "Not found: \(path)"
            }
        }
    }

    private func resolve(_ url: URL) throws -> URL {
        switch url.host {
        case "app":
            let relative = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let root = Self.webRoot.standardizedFileURL.resolvingSymlinksInPath()
            let candidate = root.appendingPathComponent(relative).standardizedFileURL
            // Reject any `..` that climbs out of the asset directory.
            guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else {
                throw Failure.forbidden(relative)
            }
            guard FileManager.default.fileExists(atPath: candidate.path) else {
                throw Failure.notFound(relative)
            }
            return candidate

        case "doc":
            guard
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                let raw = components.queryItems?.first(where: { $0.name == "p" })?.value
            else { throw Failure.badRequest }

            let candidate = URL(fileURLWithPath: raw)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard Self.isAllowed(candidate.path) else { throw Failure.forbidden(raw) }
            guard FileManager.default.fileExists(atPath: candidate.path) else {
                throw Failure.notFound(raw)
            }
            return candidate

        default:
            throw Failure.badRequest
        }
    }

    private static func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mime = type.preferredMIMEType {
            return mime
        }
        switch url.pathExtension.lowercased() {
        case "js", "mjs": return "text/javascript"
        case "css": return "text/css"
        case "woff2": return "font/woff2"
        case "html": return "text/html"
        default: return "application/octet-stream"
        }
    }
}
