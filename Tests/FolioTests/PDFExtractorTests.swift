import AppKit
import XCTest
@testable import Folio

private func blocks(_ items: [(PDFExtractor.Block.Kind, String)]) -> [PDFExtractor.Block] {
    items.map { PDFExtractor.Block(kind: $0.0, text: $0.1) }
}

final class PDFExtractorMarkdownTests: XCTestCase {
    func testHeadingLevelsMapToHashes() {
        let output = PDFExtractor.markdown(from: blocks([
            (.heading(1), "Title"), (.heading(3), "Sub"),
        ]))
        assertContains(output, "# Title", "h1 gets one hash")
        assertContains(output, "### Sub", "h3 gets three hashes")
    }

    func testBulletsAndParagraphs() {
        let output = PDFExtractor.markdown(from: blocks([
            (.paragraph, "Body text."), (.bullet, "First"), (.bullet, "Second"),
        ]))
        assertContains(output, "- First", "bullets get a dash")
        assertContains(output, "- Second", "every bullet gets a dash")
        assertContains(output, "Body text.", "paragraphs survive")
    }

    func testOutputEndsWithANewline() {
        XCTAssertTrue(PDFExtractor.markdown(from: blocks([(.paragraph, "x")])).hasSuffix("\n"))
    }

    // Extracted prose is content, not markup. None of it should format.
    func testInlineSyntaxIsEscaped() {
        let output = PDFExtractor.markdown(from: blocks([(.paragraph, "a * b _ c ` d [e]")]))
        for escaped in ["\\*", "\\_", "\\`", "\\[e\\]"] {
            assertContains(output, escaped, "\(escaped) should be escaped")
        }
    }

    func testLeadingHashCannotBecomeAHeading() {
        let output = PDFExtractor.markdown(from: blocks([(.paragraph, "# not a heading")]))
        XCTAssertTrue(output.hasPrefix("\\#"))
    }
}

final class PDFExtractorPlainTextTests: XCTestCase {
    func testNoMarkupLeaksIn() {
        let output = PDFExtractor.plainText(from: blocks([
            (.heading(1), "Title"), (.bullet, "Item"), (.paragraph, "Prose"),
        ]))
        assertContains(output, "Title", "headings appear as plain text")
        XCTAssertFalse(output.contains("#"), "no markdown syntax in plain text")
        assertContains(output, "- Item", "bullets stay readable")
    }
}

final class PDFExtractorHTMLTests: XCTestCase {
    func testHeadingsMapToTheirLevel() {
        let output = PDFExtractor.html(from: blocks([(.heading(2), "Heading")]), title: "t")
        assertContains(output, "<h2>Heading</h2>", "h2")
    }

    func testConsecutiveBulletsShareOneList() {
        let output = PDFExtractor.html(from: blocks([
            (.bullet, "One"), (.bullet, "Two"), (.paragraph, "After"),
        ]), title: "t")
        XCTAssertEqual(output.components(separatedBy: "<ul>").count - 1, 1, "one list opened")
        XCTAssertEqual(output.components(separatedBy: "</ul>").count - 1, 1, "one list closed")
        assertContains(output, "<li>One</li>", "items are wrapped")
        assertContains(output, "<p>After</p>", "the list closes before the next paragraph")
    }

    func testSeparatedBulletsMakeSeparateLists() {
        let output = PDFExtractor.html(from: blocks([
            (.bullet, "One"), (.paragraph, "Between"), (.bullet, "Two"),
        ]), title: "t")
        XCTAssertEqual(output.components(separatedBy: "<ul>").count - 1, 2)
    }

    func testTitleAndBodyAreEscaped() {
        let output = PDFExtractor.html(from: blocks([
            (.paragraph, "<script>alert(1)</script>"),
        ]), title: "Doc & Co")
        assertContains(output, "Doc &amp; Co", "the title is escaped")
        XCTAssertFalse(output.contains("<script>"), "extracted text cannot inject markup")
    }
}

final class PDFExtractorRichTextTests: XCTestCase {
    func testProducesAttributedTextConvertibleToRTF() throws {
        let attributed = PDFExtractor.attributed(from: blocks([
            (.heading(1), "Title"), (.paragraph, "Body"), (.bullet, "Item"),
        ]))
        XCTAssertGreaterThan(attributed.length, 0)
        assertContains(attributed.string, "• Item", "bullets carry a visible marker")

        let rtf = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        XCTAssertGreaterThan(rtf.count, 0)
    }

    func testHeadingsAreHeavierThanBody() {
        let attributed = PDFExtractor.attributed(from: blocks([
            (.heading(1), "Title"), (.paragraph, "Body"),
        ]))
        let headingFont = attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let bodyIndex = attributed.string.distance(
            from: attributed.string.startIndex,
            to: attributed.string.range(of: "Body")!.lowerBound
        )
        let bodyFont = attributed.attribute(.font, at: bodyIndex, effectiveRange: nil) as? NSFont
        XCTAssertGreaterThan(headingFont?.pointSize ?? 0, bodyFont?.pointSize ?? 0)
    }
}
