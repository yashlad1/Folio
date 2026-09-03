import PDFKit
import XCTest
@testable import Folio

/// End-to-end conversions over real files on disk.
@MainActor
final class ConversionIntegrationTests: XCTestCase {
    private var scratch = Scratch()

    override func setUp() {
        super.setUp()
        scratch = Scratch()
    }

    // MARK: Into PDF

    func testImageBecomesASinglePage() async throws {
        let target = scratch.path("square.pdf")
        try await Converter.convert(scratch.png("square.png"), to: .pdf, at: target)
        XCTAssertEqual(pdfPageCount(target), 1)
    }

    func testRichTextKeepsItsWords() async throws {
        let source = scratch.rtf("memo.rtf", text: "Quarterly figures are attached for review.")
        let target = scratch.path("memo.pdf")
        try await Converter.convert(source, to: .pdf, at: target)
        XCTAssertGreaterThanOrEqual(pdfPageCount(target), 1)
        assertContains(pdfText(target), "Quarterly figures", "the text survives into the PDF")
    }

    func testMarkdownRendersThroughTheRealRenderer() async throws {
        let source = scratch.file("note.md", """
        # Release Notes

        A paragraph of prose that is long enough to occupy a line of its own.

        | Key | Value |
        |-----|-------|
        | one | two   |
        """)
        let target = scratch.path("note.pdf")
        try await Converter.convert(source, to: .pdf, at: target)

        let text = pdfText(target)
        XCTAssertGreaterThanOrEqual(pdfPageCount(target), 1)
        // A blank page is the classic failure here and is invisible in the
        // byte count, so the assertion goes through the text layer.
        XCTAssertFalse(
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "the exported page must not be blank"
        )
        assertContains(text, "Release Notes", "the heading renders")
        assertContains(text, "Value", "the table renders")
    }

    func testLongDocumentPaginates() async throws {
        var body = "# Long\n\n"
        for index in 1...60 {
            body += "Paragraph number \(index) with enough words to take a full line of the column.\n\n"
        }
        let target = scratch.path("long.pdf")
        try await Converter.convert(scratch.file("long.md", body), to: .pdf, at: target)

        XCTAssertGreaterThan(pdfPageCount(target), 1, "a long document spans multiple pages")
        assertContains(pdfText(target), "Paragraph number 60", "content near the end is not dropped")
    }

    // MARK: Back out of PDF

    private func makePDF(_ name: String, from markdown: String) async throws -> URL {
        let pdf = scratch.path(name)
        try await Converter.convert(scratch.file("\(name).md", markdown), to: .pdf, at: pdf)
        return pdf
    }

    func testEveryTextFormatIsWritten() async throws {
        let pdf = try await makePDF("round.pdf", from: "# Title\n\nSome prose to extract.\n")
        for format in [ConversionFormat.markdown, .plainText, .richText, .html] {
            let target = scratch.path("out.\(format.fileExtension)")
            try await Converter.convert(pdf, to: format, at: target)
            XCTAssertGreaterThan(fileSize(target), 0, "\(format.label) output is non-empty")
        }
    }

    func testStructureIsRecovered() async throws {
        let pdf = try await makePDF("structured.pdf", from: """
        # Annual Review

        An opening paragraph that runs on for long enough that it will be wrapped across more than one line when it is laid out into the printed column of text on the page.

        ## Details

        - First item in the list
        - Second item in the list
        - Third item in the list
        """)
        let out = scratch.path("recovered.md")
        try await Converter.convert(pdf, to: .markdown, at: out)
        let recovered = try String(contentsOf: out, encoding: .utf8)

        assertContains(recovered, "# Annual Review", "the top-level heading comes back")
        assertContains(recovered, "## Details", "the second level keeps its level")
        assertContains(recovered, "- First item in the list",
                       "list items are recovered from their indentation")
        assertContains(recovered, "wrapped across more than one line when it is laid out",
                       "hard-wrapped lines are rejoined into one paragraph")
    }

    /// List recovery keys off indentation, and code blocks are indented too.
    /// Excluding monospaced lines is the only thing stopping every line of
    /// every code sample from becoming a bullet.
    func testCodeIsNotMistakenForAList() async throws {
        let pdf = try await makePDF("code.pdf", from: """
        # Sample

        An ordinary paragraph of prose long enough to wrap onto a second line when laid out into the printed column.

        ```swift
        struct Folio {
            let bundled = true
        }
        ```
        """)
        let out = scratch.path("code-recovered.md")
        try await Converter.convert(pdf, to: .markdown, at: out)
        let recovered = try String(contentsOf: out, encoding: .utf8)

        let bulleted = recovered.split(separator: "\n").filter {
            $0.hasPrefix("- ") && ($0.contains("struct Folio") || $0.contains("bundled"))
        }
        XCTAssertTrue(bulleted.isEmpty, "code lines must not become bullets, got \(bulleted)")
        assertContains(recovered, "struct Folio", "the code itself is still recovered")
    }

    func testPageImagesAreWrittenOnePerPage() async throws {
        let pdf = try await makePDF("pages.pdf", from: "# One\n\ntext\n")
        let folder = scratch.path("pages-out")
        try await Converter.convert(pdf, to: .pngPages, at: folder)

        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(files.count, pdfPageCount(pdf), "one image per page")
        XCTAssertTrue(files.allSatisfy { $0.hasSuffix(".png") })
        XCTAssertEqual(files.first, "page-001.png", "numbered from one, zero padded")
    }

    func testPDFPassedToPDFIsCopiedIntact() async throws {
        let pdf = try await makePDF("passthrough.pdf", from: "# Copy me\n")
        let copy = scratch.path("copy.pdf")
        try await Converter.convert(pdf, to: .pdf, at: copy)
        XCTAssertEqual(pdfPageCount(copy), pdfPageCount(pdf))
    }

    // MARK: Refusals

    func testUnknownExtensionIsRefused() async {
        let source = scratch.file("thing.xyz", "data")
        do {
            try await Converter.convert(source, to: .pdf, at: scratch.path("thing.pdf"))
            XCTFail("expected an error for an unsupported source")
        } catch {}
    }

    func testUnreachableTargetIsRefused() async {
        // Markdown is only reachable from a PDF, never from markdown.
        let source = scratch.file("x.md", "# hi")
        do {
            try await Converter.convert(source, to: .markdown, at: scratch.path("x-out.md"))
            XCTFail("expected an error for an unreachable target format")
        } catch {}
    }

    func testMissingSourceIsRefused() async {
        do {
            try await Converter.convert(
                scratch.path("nope.png"), to: .pdf, at: scratch.path("nope.pdf")
            )
            XCTFail("expected an error for a missing source")
        } catch {}
    }
}
