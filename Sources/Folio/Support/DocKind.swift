import Foundation
import UniformTypeIdentifiers

/// The two families of document Folio knows how to display.
enum DocKind: String {
    case markdown
    case pdf

    /// Extensions rendered through the markdown pipeline. Plain-text kinds are
    /// included deliberately: markdown degrades gracefully to prose.
    static let markdownExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtxt", "mdtext",
        "qmd", "rmd", "txt", "text", "log", "csv",
    ]

    static func of(_ url: URL) -> DocKind? {
        switch url.pathExtension.lowercased() {
        case "pdf": return .pdf
        case let ext where markdownExtensions.contains(ext): return .markdown
        default: return nil
        }
    }

    var symbol: String {
        switch self {
        case .markdown: return "doc.text"
        case .pdf: return "doc.richtext"
        }
    }
}

enum TextFile {
    /// Reads a text file, falling back through encodings rather than failing.
    static func read(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        for encoding in [String.Encoding.utf8, .utf16, .isoLatin1, .macOSRoman] {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        return String(decoding: data, as: UTF8.self)
    }
}
