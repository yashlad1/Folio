import AppKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// What a file can be turned into.
///
/// Folio converts *to* PDF from anything it can read, and *back* from PDF into
/// the text and image formats below. Cross-conversions that would round-trip
/// through PDF for no reason (Word to RTF, say) are deliberately not offered:
/// they would lose formatting without gaining anything.
enum ConversionFormat: String, CaseIterable, Identifiable {
    case pdf
    case markdown
    case plainText
    case richText
    case html
    case pngPages

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pdf: return "PDF"
        case .markdown: return "Markdown"
        case .plainText: return "Plain Text"
        case .richText: return "Rich Text"
        case .html: return "HTML"
        case .pngPages: return "PNG Images"
        }
    }

    /// Extension for the produced file. PNG output is a folder, so it has none.
    var fileExtension: String {
        switch self {
        case .pdf: return "pdf"
        case .markdown: return "md"
        case .plainText: return "txt"
        case .richText: return "rtf"
        case .html: return "html"
        case .pngPages: return ""
        }
    }

    var contentType: UTType {
        switch self {
        case .pdf: return .pdf
        case .markdown: return UTType("net.daringfireball.markdown") ?? .plainText
        case .plainText: return .plainText
        case .richText: return .rtf
        case .html: return .html
        case .pngPages: return .folder
        }
    }

    /// PNG export writes one image per page into a directory.
    var producesDirectory: Bool { self == .pngPages }

    /// The targets reachable from a given source. PDF is listed for a PDF
    /// source so that a mixed batch can still be normalised to PDF — there it
    /// is a copy, not a conversion.
    static func available(for family: SourceFamily) -> [ConversionFormat] {
        family == .pdf
            ? [.pdf, .markdown, .plainText, .richText, .html, .pngPages]
            : [.pdf]
    }

    /// The targets worth offering for a whole selection. Converting a lone PDF
    /// to PDF is not a thing anyone wants, so it is offered only when the batch
    /// also holds files that genuinely need converting.
    static func available(forSources families: [SourceFamily]) -> [ConversionFormat] {
        guard !families.isEmpty else { return [] }
        if families.allSatisfy({ $0 == .pdf }) {
            return [.markdown, .plainText, .richText, .html, .pngPages]
        }
        return [.pdf]
    }
}

/// How a source file has to be read. Conversion routes on this rather than on
/// the extension directly, so teaching Folio a new input is a one-line change.
enum SourceFamily: Equatable {
    case pdf
    /// Markdown and the plain-text kinds Folio already renders.
    case markdown
    case html
    case image
    /// Anything `NSAttributedString` can open: RTF, Word, OpenDocument.
    case wordProcessing

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "gif", "tiff", "tif",
        "bmp", "webp", "ico", "jp2", "avif",
    ]

    static let wordProcessingExtensions: Set<String> = [
        "rtf", "rtfd", "doc", "docx", "odt", "wordml", "webarchive",
    ]

    static let htmlExtensions: Set<String> = ["html", "htm", "xhtml"]

    static func of(_ url: URL) -> SourceFamily? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if htmlExtensions.contains(ext) { return .html }
        if imageExtensions.contains(ext) { return .image }
        if wordProcessingExtensions.contains(ext) { return .wordProcessing }
        if DocKind.markdownExtensions.contains(ext) { return .markdown }
        // Extensionless or unknown files are treated as text if they decode.
        if ext.isEmpty { return .markdown }
        return nil
    }
}

enum ConversionError: LocalizedError {
    case unsupportedSource(URL)
    case unsupportedTarget(ConversionFormat, SourceFamily)
    case unreadable(URL)
    case noTextLayer(URL)
    case renderFailed(String)
    case writeFailed(URL)

    var errorDescription: String? {
        switch self {
        case .unsupportedSource(let url):
            return "Folio cannot convert .\(url.pathExtension) files"
        case .unsupportedTarget(let format, _):
            return "Cannot produce \(format.label) from this file"
        case .unreadable(let url):
            return "Could not read \(url.lastPathComponent)"
        case .noTextLayer(let url):
            return "\(url.lastPathComponent) has no selectable text — it is probably scanned images"
        case .renderFailed(let detail):
            return detail
        case .writeFailed(let url):
            return "Could not write \(url.lastPathComponent)"
        }
    }
}

/// Page geometry shared by printing and every PDF the converter produces, so a
/// file exported from a menu matches one produced in a batch.
enum PrintSetup {
    static func info() -> NSPrintInfo {
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

    /// Print settings that write straight to `url` with no panels.
    static func savingInfo(to url: URL) -> NSPrintInfo {
        let info = info()
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url as NSURL
        return info
    }
}

// MARK: - Converter

@MainActor
enum Converter {
    /// Converts `source` into `format`, writing to `destination`.
    ///
    /// `destination` is a file for every format except `.pngPages`, which
    /// receives a directory holding one image per page.
    static func convert(_ source: URL, to format: ConversionFormat, at destination: URL) async throws {
        guard let family = SourceFamily.of(source) else {
            throw ConversionError.unsupportedSource(source)
        }
        guard ConversionFormat.available(for: family).contains(format) else {
            throw ConversionError.unsupportedTarget(format, family)
        }

        if format == .pdf {
            try await toPDF(source, family: family, destination: destination)
        } else {
            try fromPDF(source, format: format, destination: destination)
        }
    }

    /// The filename `source` should get once converted, without a directory.
    static func outputName(for source: URL, format: ConversionFormat) -> String {
        let stem = source.deletingPathExtension().lastPathComponent
        if format.producesDirectory { return "\(stem) pages" }
        return "\(stem).\(format.fileExtension)"
    }

    /// A destination that does not already exist, so converting never
    /// overwrites the user's files — including the source itself, which a
    /// PDF-to-PDF pass in the same folder would otherwise clobber.
    static func vacantDestination(_ proposed: URL) -> URL {
        let manager = FileManager.default
        guard manager.fileExists(atPath: proposed.path) else { return proposed }

        let directory = proposed.deletingLastPathComponent()
        let ext = proposed.pathExtension
        let stem = proposed.deletingPathExtension().lastPathComponent
        for attempt in 2...999 {
            let name = ext.isEmpty ? "\(stem) \(attempt)" : "\(stem) \(attempt).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !manager.fileExists(atPath: candidate.path) { return candidate }
        }
        return proposed
    }

    // MARK: To PDF

    private static func toPDF(_ source: URL, family: SourceFamily, destination: URL) async throws {
        switch family {
        case .pdf:
            // Already a PDF; copying keeps batch conversion total.
            if source.standardizedFileURL == destination.standardizedFileURL { return }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: source, to: destination)

        case .image:
            try imagesToPDF(source, destination: destination)

        case .wordProcessing:
            try wordProcessingToPDF(source, destination: destination)

        case .markdown:
            let text = try TextFile.read(source)
            try await OffscreenRenderer.shared.pdf(
                fromMarkdown: text,
                extension: source.pathExtension.lowercased(),
                documentDirectory: source.deletingLastPathComponent(),
                to: destination
            )

        case .html:
            try await OffscreenRenderer.shared.pdf(fromHTMLFile: source, to: destination)
        }
    }

    /// One PDF page per image frame, so multi-page TIFFs and animated GIFs
    /// survive instead of collapsing to their first frame.
    private static func imagesToPDF(_ source: URL, destination: URL) throws {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            throw ConversionError.unreadable(source)
        }
        let document = PDFDocument()
        var pageIndex = 0
        for frame in 0..<max(CGImageSourceGetCount(imageSource), 1) {
            guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, frame, nil) else { continue }
            let size = NSSize(width: cgImage.width, height: cgImage.height)
            guard let page = PDFPage(image: NSImage(cgImage: cgImage, size: size)) else { continue }
            document.insert(page, at: pageIndex)
            pageIndex += 1
        }
        guard pageIndex > 0 else { throw ConversionError.unreadable(source) }
        guard document.write(to: destination) else { throw ConversionError.writeFailed(destination) }
    }

    /// Word, RTF and OpenDocument go through TextKit, which paginates the
    /// styled text far more faithfully than an HTML round-trip would.
    private static func wordProcessingToPDF(_ source: URL, destination: URL) throws {
        let attributed: NSAttributedString
        do {
            attributed = try NSAttributedString(url: source, options: [:], documentAttributes: nil)
        } catch {
            throw ConversionError.unreadable(source)
        }

        let info = PrintSetup.savingInfo(to: destination)
        let width = info.paperSize.width - info.leftMargin - info.rightMargin

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textStorage?.setAttributedString(attributed)
        if let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
        }
        textView.sizeToFit()

        let operation = NSPrintOperation(view: textView, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run() else { throw ConversionError.writeFailed(destination) }
    }

    // MARK: Back from PDF

    private static func fromPDF(_ source: URL, format: ConversionFormat, destination: URL) throws {
        guard let document = PDFDocument(url: source) else {
            throw ConversionError.unreadable(source)
        }

        if format == .pngPages {
            try PDFExtractor.writePageImages(from: document, into: destination)
            return
        }

        let extracted = PDFExtractor.blocks(from: document)
        guard !extracted.isEmpty else { throw ConversionError.noTextLayer(source) }

        let title = source.deletingPathExtension().lastPathComponent
        let data: Data
        switch format {
        case .markdown:
            data = Data(PDFExtractor.markdown(from: extracted).utf8)
        case .plainText:
            data = Data(PDFExtractor.plainText(from: extracted).utf8)
        case .html:
            data = Data(PDFExtractor.html(from: extracted, title: title).utf8)
        case .richText:
            let attributed = PDFExtractor.attributed(from: extracted)
            data = try attributed.data(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            )
        case .pdf, .pngPages:
            throw ConversionError.unsupportedTarget(format, .pdf)
        }

        do {
            try data.write(to: destination)
        } catch {
            throw ConversionError.writeFailed(destination)
        }
    }
}
