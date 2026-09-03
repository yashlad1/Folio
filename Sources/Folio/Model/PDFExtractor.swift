import AppKit
import Foundation
import PDFKit

/// Recovers structure from a PDF's text layer.
///
/// A PDF stores glyphs and positions, not headings and paragraphs, so the
/// structure here is inferred: type size relative to the document's body size
/// marks headings, and a line that stops well short of the measured wrap width
/// is treated as the end of a paragraph rather than a hard break. The results
/// are good on text documents and only approximate on heavily designed ones,
/// which is the honest ceiling for this without OCR or tagged-PDF metadata.
enum PDFExtractor {
    struct Block {
        enum Kind: Equatable {
            case heading(Int)
            case paragraph
            case bullet
        }

        var kind: Kind
        var text: String
    }

    private struct Line {
        var text: String
        var size: CGFloat
        var isBold: Bool
        /// Left edge on the page, in PDF points. List items sit in from the
        /// body margin, which is the only trace of a list that survives when
        /// the marker itself was drawn by CSS rather than set as text.
        var leftEdge: CGFloat
        var isMonospace: Bool
    }

    // MARK: Reading

    static func blocks(from document: PDFDocument) -> [Block] {
        var lines: [Line] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index),
                  let attributed = page.attributedString
            else { continue }
            lines.append(contentsOf: measure(attributed, on: page))
        }
        guard !lines.isEmpty else { return [] }

        let bodySize = dominantSize(of: lines)
        // The widest body line approximates the text column, which is what a
        // short line is short *relative to*.
        let wrapWidth = lines
            .filter { headingLevel(size: $0.size, isBold: $0.isBold, body: bodySize, length: $0.text.count) == nil }
            .map(\.text.count)
            .max() ?? 80

        let bodyLeft = dominantLeftEdge(of: lines)

        var blocks: [Block] = []
        var buffer: [String] = []
        var bufferKind = Block.Kind.paragraph

        func flush() {
            guard !buffer.isEmpty else { return }
            blocks.append(Block(kind: bufferKind, text: buffer.joined(separator: " ")))
            buffer.removeAll()
        }

        for line in lines {
            if let level = headingLevel(
                size: line.size, isBold: line.isBold, body: bodySize, length: line.text.count
            ) {
                flush()
                blocks.append(Block(kind: .heading(level), text: line.text))
                continue
            }

            var kind = Block.Kind.paragraph
            var text = line.text

            if let item = bulletContent(of: line.text) {
                // An explicit marker always starts a new item, even mid-run.
                flush()
                kind = .bullet
                text = item
            } else if line.leftEdge > bodyLeft + Self.listIndent, !line.isMonospace {
                // No marker in the text layer, but the line is indented past
                // the body margin. Code blocks are indented too, which is why
                // monospaced lines are excluded here.
                kind = .bullet
            }

            if kind != bufferKind {
                flush()
                bufferKind = kind
            }
            buffer.append(text)
            // A line stopping well short of the column ends its block; anything
            // else is a hard-wrapped continuation of the same one.
            if Double(text.count) < Double(wrapWidth) * 0.55 { flush() }
        }
        flush()

        return blocks
    }

    /// Splits an extracted page into lines carrying their dominant type size.
    private static func measure(_ attributed: NSAttributedString, on page: PDFPage) -> [Line] {
        let string = attributed.string as NSString
        var lines: [Line] = []

        string.enumerateSubstrings(
            in: NSRange(location: 0, length: string.length),
            options: [.byLines]
        ) { substring, range, _, _ in
            guard let substring else { return }
            let text = substring.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return }

            var weights: [CGFloat: Int] = [:]
            var boldCount = 0
            var monoCount = 0
            var total = 0
            attributed.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
                guard let font = value as? NSFont else { return }
                weights[font.pointSize.rounded(), default: 0] += subrange.length
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.bold) { boldCount += subrange.length }
                if traits.contains(.monoSpace) { monoCount += subrange.length }
                total += subrange.length
            }

            lines.append(Line(
                text: text,
                size: weights.max { $0.value < $1.value }?.key ?? 12,
                isBold: total > 0 && boldCount * 2 > total,
                leftEdge: page.characterBounds(at: range.location).minX,
                isMonospace: total > 0 && monoCount * 2 > total
            ))
        }
        return lines
    }

    /// How far past the body margin a line must sit to read as a list item.
    private static let listIndent: CGFloat = 6

    /// The margin the bulk of the text hangs from, bucketed so that sub-point
    /// jitter in the glyph positions does not split the histogram.
    private static func dominantLeftEdge(of lines: [Line]) -> CGFloat {
        var weights: [CGFloat: Int] = [:]
        for line in lines {
            weights[(line.leftEdge / 2).rounded() * 2, default: 0] += line.text.count
        }
        return weights.max { $0.value < $1.value }?.key ?? 0
    }

    /// Body size is whichever size covers the most characters.
    private static func dominantSize(of lines: [Line]) -> CGFloat {
        var weights: [CGFloat: Int] = [:]
        for line in lines { weights[line.size, default: 0] += line.text.count }
        return weights.max { $0.value < $1.value }?.key ?? 12
    }

    private static func headingLevel(
        size: CGFloat, isBold: Bool, body: CGFloat, length: Int
    ) -> Int? {
        guard body > 0 else { return nil }
        let ratio = size / body
        if ratio >= 1.60 { return 1 }
        if ratio >= 1.32 { return 2 }
        if ratio >= 1.12 { return 3 }
        // A fully bold, short line at body size reads as a run-in subheading.
        if isBold, ratio >= 0.98, length <= 80 { return 4 }
        return nil
    }

    private static let bulletMarkers: Set<Character> = ["•", "◦", "▪", "‣", "·", "–", "—", "-", "*"]

    private static func bulletContent(of text: String) -> String? {
        guard let first = text.first, bulletMarkers.contains(first) else { return nil }
        let rest = text.dropFirst().trimmingCharacters(in: .whitespaces)
        // "-" alone, or a dash starting a sentence, is not a list.
        return rest.isEmpty ? nil : rest
    }

    // MARK: Writing

    static func markdown(from blocks: [Block]) -> String {
        var out: [String] = []
        for block in blocks {
            switch block.kind {
            case .heading(let level):
                out.append(String(repeating: "#", count: level) + " " + escapeMarkdown(block.text))
            case .bullet:
                out.append("- " + escapeMarkdown(block.text))
            case .paragraph:
                out.append(escapeMarkdown(block.text))
            }
        }
        return out.joined(separator: "\n\n") + "\n"
    }

    static func plainText(from blocks: [Block]) -> String {
        blocks.map { block in
            if case .bullet = block.kind { return "- " + block.text }
            return block.text
        }
        .joined(separator: "\n\n") + "\n"
    }

    static func html(from blocks: [Block], title: String) -> String {
        var body: [String] = []
        var openList = false

        func closeList() {
            if openList {
                body.append("</ul>")
                openList = false
            }
        }

        for block in blocks {
            switch block.kind {
            case .bullet:
                if !openList {
                    body.append("<ul>")
                    openList = true
                }
                body.append("<li>\(escapeHTML(block.text))</li>")
            case .heading(let level):
                closeList()
                body.append("<h\(level)>\(escapeHTML(block.text))</h\(level)>")
            case .paragraph:
                closeList()
                body.append("<p>\(escapeHTML(block.text))</p>")
            }
        }
        closeList()

        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <title>\(escapeHTML(title))</title>
        <style>
        body { max-width: 42rem; margin: 3rem auto; padding: 0 1.5rem;
               font: 16px/1.65 -apple-system, system-ui, sans-serif; color: #1c1c1e; }
        h1, h2, h3, h4 { line-height: 1.25; margin: 2rem 0 0.75rem; }
        </style>
        </head>
        <body>
        \(body.joined(separator: "\n"))
        </body>
        </html>

        """
    }

    static func attributed(from blocks: [Block]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let bodySize: CGFloat = 12

        for block in blocks {
            let font: NSFont
            let text: String
            switch block.kind {
            case .heading(let level):
                // h1 at 20pt down to h4 at body weight, all bold.
                let size = max(bodySize, bodySize + CGFloat(5 - level) * 2)
                font = .boldSystemFont(ofSize: size)
                text = block.text
            case .bullet:
                font = .systemFont(ofSize: bodySize)
                text = "• " + block.text
            case .paragraph:
                font = .systemFont(ofSize: bodySize)
                text = block.text
            }

            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.paragraphSpacing = 8
            if case .bullet = block.kind { paragraphStyle.headIndent = 16 }

            result.append(NSAttributedString(
                string: text + "\n",
                attributes: [.font: font, .paragraphStyle: paragraphStyle]
            ))
        }
        return result
    }

    /// One PNG per page, rendered at 2x so the output is usable rather than
    /// merely accurate.
    static func writePageImages(from document: PDFDocument, into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var written = 0
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width > 0, bounds.height > 0 else { continue }

            let size = NSSize(width: bounds.width * 2, height: bounds.height * 2)
            let image = page.thumbnail(of: size, for: .mediaBox)
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:])
            else { continue }

            let name = String(format: "page-%03d.png", index + 1)
            try png.write(to: directory.appendingPathComponent(name))
            written += 1
        }

        guard written > 0 else { throw ConversionError.writeFailed(directory) }
    }

    // MARK: Escaping

    /// Neutralises characters that would otherwise be read as markup. Extracted
    /// prose is content, not markdown, so none of it should format.
    private static func escapeMarkdown(_ text: String) -> String {
        var result = ""
        for character in text {
            if "\\`*_[]<>".contains(character) { result.append("\\") }
            result.append(character)
        }
        // Leading characters only matter at the start of a line.
        if let first = result.first, "#>|+".contains(first) {
            result = "\\" + result
        }
        return result
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
