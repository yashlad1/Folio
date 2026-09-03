import AppKit
import Foundation
import WebKit

// MARK: - File classification

func testDocKind() {
    T.suite("DocKind")
    T.equal(DocKind.of(URL(fileURLWithPath: "/a/notes.md")), .markdown, "recognises .md")
    T.equal(DocKind.of(URL(fileURLWithPath: "/a/notes.MD")), .markdown, "extension match is case-insensitive")
    T.equal(DocKind.of(URL(fileURLWithPath: "/a/data.csv")), .markdown, "csv renders through the markdown pipeline")
    T.equal(DocKind.of(URL(fileURLWithPath: "/a/paper.pdf")), .pdf, "recognises .pdf")
    T.equal(DocKind.of(URL(fileURLWithPath: "/a/archive.zip")), nil, "rejects unknown kinds")
}

func testSourceFamily() {
    T.suite("SourceFamily")
    T.equal(SourceFamily.of(URL(fileURLWithPath: "/a/x.pdf")), .pdf, "pdf")
    T.equal(SourceFamily.of(URL(fileURLWithPath: "/a/x.md")), .markdown, "markdown")
    T.equal(SourceFamily.of(URL(fileURLWithPath: "/a/x.txt")), .markdown, "plain text joins the markdown family")
    T.equal(SourceFamily.of(URL(fileURLWithPath: "/a/x.html")), .html, "html")
    T.equal(SourceFamily.of(URL(fileURLWithPath: "/a/x.HTM")), .html, "html, upper case")
    T.equal(SourceFamily.of(URL(fileURLWithPath: "/a/x.png")), .image, "image")
    T.equal(SourceFamily.of(URL(fileURLWithPath: "/a/x.heic")), .image, "modern image formats")
    T.equal(SourceFamily.of(URL(fileURLWithPath: "/a/x.docx")), .wordProcessing, "word processing")
    T.equal(SourceFamily.of(URL(fileURLWithPath: "/a/x.odt")), .wordProcessing, "opendocument")
    T.equal(SourceFamily.of(URL(fileURLWithPath: "/a/README")), .markdown, "extensionless files are treated as text")
    T.equal(SourceFamily.of(URL(fileURLWithPath: "/a/x.xyz")), nil, "unknown extensions are refused")
}

// MARK: - What converts into what

func testConversionAvailability() {
    T.suite("ConversionFormat availability")
    let fromPDF = ConversionFormat.available(for: .pdf)
    T.check(fromPDF.contains(.markdown) && fromPDF.contains(.plainText)
            && fromPDF.contains(.richText) && fromPDF.contains(.html)
            && fromPDF.contains(.pngPages), "a PDF converts back to every text and image form")

    T.equal(ConversionFormat.available(for: .markdown), [.pdf], "markdown only goes to PDF")
    T.equal(ConversionFormat.available(for: .image), [.pdf], "images only go to PDF")

    T.equal(ConversionFormat.available(forSources: []), [], "no sources offers no targets")
    T.check(!ConversionFormat.available(forSources: [.pdf]).contains(.pdf),
            "a lone PDF is not offered PDF as a target")
    T.equal(ConversionFormat.available(forSources: [.pdf, .markdown]), [.pdf],
            "a mixed batch normalises to PDF")
    T.equal(ConversionFormat.available(forSources: [.markdown, .image]), [.pdf],
            "a batch of convertibles targets PDF")
}

func testFormatMetadata() {
    T.suite("ConversionFormat metadata")
    T.equal(ConversionFormat.pdf.fileExtension, "pdf", "pdf extension")
    T.equal(ConversionFormat.markdown.fileExtension, "md", "markdown extension")
    T.equal(ConversionFormat.richText.fileExtension, "rtf", "rtf extension")
    T.check(ConversionFormat.pngPages.producesDirectory, "png output is a directory")
    T.check(!ConversionFormat.pdf.producesDirectory, "pdf output is a file")
    T.check(ConversionFormat.allCases.allSatisfy { !$0.label.isEmpty }, "every format has a label")
}

// MARK: - Naming and overwrite safety

func testOutputNaming() {
    T.suite("Output naming")
    let source = URL(fileURLWithPath: "/docs/Report Q3.md")
    T.equal(Converter.outputName(for: source, format: .pdf), "Report Q3.pdf", "keeps the stem, swaps the extension")
    T.equal(Converter.outputName(for: source, format: .pngPages), "Report Q3 pages", "png output names a folder")
    T.equal(Converter.outputName(for: URL(fileURLWithPath: "/docs/a.b.c.md"), format: .pdf), "a.b.c.pdf",
            "only the final extension is replaced")
}

func testVacantDestination() {
    T.suite("Overwrite safety")
    let free = Scratch.path("nothing-here.pdf")
    T.equal(Converter.vacantDestination(free), free, "an unused path is returned unchanged")

    let taken = Scratch.file("taken.pdf", "x")
    let second = Converter.vacantDestination(taken)
    T.equal(second.lastPathComponent, "taken 2.pdf", "an existing file is stepped around")
    T.check(!FileManager.default.fileExists(atPath: second.path), "the stepped-around path is genuinely free")

    try? "x".write(to: Scratch.path("taken 2.pdf"), atomically: true, encoding: .utf8)
    T.equal(Converter.vacantDestination(taken).lastPathComponent, "taken 3.pdf", "it keeps stepping")

    let folder = Scratch.path("pages")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    T.equal(Converter.vacantDestination(folder).lastPathComponent, "pages 2",
            "extensionless directory names step without gaining an extension")
}

// MARK: - PDF text reassembly

private func blocks(_ items: [(PDFExtractor.Block.Kind, String)]) -> [PDFExtractor.Block] {
    items.map { PDFExtractor.Block(kind: $0.0, text: $0.1) }
}

func testMarkdownRendering() {
    T.suite("PDFExtractor › markdown output")
    let output = PDFExtractor.markdown(from: blocks([
        (.heading(1), "Title"), (.paragraph, "Body text."),
        (.heading(3), "Sub"), (.bullet, "First"), (.bullet, "Second"),
    ]))
    T.contains(output, "# Title", "h1 gets one hash")
    T.contains(output, "### Sub", "h3 gets three hashes")
    T.contains(output, "- First", "bullets get a dash")
    T.contains(output, "Body text.", "paragraphs survive")
    T.check(output.hasSuffix("\n"), "output ends with a newline")
}

func testMarkdownEscaping() {
    T.suite("PDFExtractor › markdown escaping")
    // Extracted prose is content, not markup: nothing in it should format.
    let output = PDFExtractor.markdown(from: blocks([(.paragraph, "a * b _ c ` d [e]")]))
    T.contains(output, "\\*", "asterisks are escaped")
    T.contains(output, "\\_", "underscores are escaped")
    T.contains(output, "\\`", "backticks are escaped")
    T.contains(output, "\\[e\\]", "brackets are escaped")

    let leading = PDFExtractor.markdown(from: blocks([(.paragraph, "# not a heading")]))
    T.check(leading.hasPrefix("\\#"), "a leading hash is escaped so prose cannot become a heading")
}

func testPlainTextRendering() {
    T.suite("PDFExtractor › plain text output")
    let output = PDFExtractor.plainText(from: blocks([
        (.heading(1), "Title"), (.bullet, "Item"), (.paragraph, "Prose"),
    ]))
    T.contains(output, "Title", "headings appear without markup")
    T.check(!output.contains("#"), "no markdown syntax leaks into plain text")
    T.contains(output, "- Item", "bullets stay readable")
}

func testHTMLRendering() {
    T.suite("PDFExtractor › html output")
    let output = PDFExtractor.html(from: blocks([
        (.heading(2), "Heading"), (.bullet, "One"), (.bullet, "Two"), (.paragraph, "After"),
    ]), title: "Doc & Co")
    T.contains(output, "<h2>Heading</h2>", "headings map to their level")
    T.equal(output.components(separatedBy: "<ul>").count - 1, 1, "consecutive bullets share one list")
    T.equal(output.components(separatedBy: "</ul>").count - 1, 1, "the list is closed once")
    T.contains(output, "<li>One</li>", "items are wrapped")
    T.contains(output, "<p>After</p>", "the list closes before the next paragraph")
    T.contains(output, "Doc &amp; Co", "the title is escaped")

    let unsafe = PDFExtractor.html(from: blocks([(.paragraph, "<script>alert(1)</script>")]), title: "t")
    T.check(!unsafe.contains("<script>"), "extracted text cannot inject markup")
}

func testAttributedRendering() {
    T.suite("PDFExtractor › rich text output")
    let attributed = PDFExtractor.attributed(from: blocks([
        (.heading(1), "Title"), (.paragraph, "Body"), (.bullet, "Item"),
    ]))
    T.check(attributed.length > 0, "produces attributed text")
    T.contains(attributed.string, "• Item", "bullets carry a visible marker")

    let rtf = try? attributed.data(
        from: NSRange(location: 0, length: attributed.length),
        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
    )
    T.check((rtf?.count ?? 0) > 0, "converts to RTF data")
}

// MARK: - The offline guard

func testOfflineGuardRules() async {
    T.suite("Offline guard")
    let rules = OffscreenRenderer.blockRules

    let parsed = try? JSONSerialization.jsonObject(with: Data(rules.utf8)) as? [[String: Any]]
    T.check((parsed??.count ?? 0) >= 2, "the rule list is valid JSON with a block and allow rules")
    T.check(!rules.contains("|"),
            "no alternation — WebKit's content-blocker regex rejects it, which silently disarms the guard")
    for scheme in ["folio", "file", "data", "blob", "about"] {
        T.contains(rules, "^\(scheme):", "\(scheme): is re-admitted")
    }

    // The real check: WebKit itself must accept the list.
    let compiled: WKContentRuleList? = await withCheckedContinuation { continuation in
        WKContentRuleListStore.default()?.compileContentRuleList(
            forIdentifier: "folio-test-guard", encodedContentRuleList: rules
        ) { list, _ in continuation.resume(returning: list) }
    }
    T.check(compiled != nil, "WebKit compiles the rule list")
}
