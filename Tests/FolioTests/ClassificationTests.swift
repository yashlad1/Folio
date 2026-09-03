import XCTest
@testable import Folio

final class DocKindTests: XCTestCase {
    func testRecognisesMarkdown() {
        XCTAssertEqual(DocKind.of(URL(fileURLWithPath: "/a/notes.md")), .markdown)
        XCTAssertEqual(DocKind.of(URL(fileURLWithPath: "/a/notes.markdown")), .markdown)
    }

    func testExtensionMatchingIsCaseInsensitive() {
        XCTAssertEqual(DocKind.of(URL(fileURLWithPath: "/a/notes.MD")), .markdown)
        XCTAssertEqual(DocKind.of(URL(fileURLWithPath: "/a/paper.PDF")), .pdf)
    }

    func testPlainTextKindsRenderThroughMarkdown() {
        for name in ["data.csv", "server.log", "readme.txt"] {
            XCTAssertEqual(DocKind.of(URL(fileURLWithPath: "/a/\(name)")), .markdown, name)
        }
    }

    func testRecognisesPDF() {
        XCTAssertEqual(DocKind.of(URL(fileURLWithPath: "/a/paper.pdf")), .pdf)
    }

    func testRejectsUnknownKinds() {
        XCTAssertNil(DocKind.of(URL(fileURLWithPath: "/a/archive.zip")))
        XCTAssertNil(DocKind.of(URL(fileURLWithPath: "/a/binary")))
    }
}

final class SourceFamilyTests: XCTestCase {
    func testClassifiesEverySupportedFamily() {
        let cases: [(String, SourceFamily)] = [
            ("x.pdf", .pdf),
            ("x.md", .markdown), ("x.txt", .markdown), ("x.csv", .markdown),
            ("x.html", .html), ("x.HTM", .html), ("x.xhtml", .html),
            ("x.png", .image), ("x.jpeg", .image), ("x.heic", .image), ("x.tiff", .image),
            ("x.rtf", .wordProcessing), ("x.doc", .wordProcessing),
            ("x.docx", .wordProcessing), ("x.odt", .wordProcessing),
        ]
        for (name, expected) in cases {
            XCTAssertEqual(SourceFamily.of(URL(fileURLWithPath: "/a/\(name)")), expected, name)
        }
    }

    func testExtensionlessFilesAreTreatedAsText() {
        XCTAssertEqual(SourceFamily.of(URL(fileURLWithPath: "/a/README")), .markdown)
    }

    func testRefusesUnknownExtensions() {
        XCTAssertNil(SourceFamily.of(URL(fileURLWithPath: "/a/x.xyz")))
        XCTAssertNil(SourceFamily.of(URL(fileURLWithPath: "/a/x.zip")))
    }
}
