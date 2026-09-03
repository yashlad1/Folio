import XCTest
@testable import Folio

final class ConversionAvailabilityTests: XCTestCase {
    func testPDFConvertsBackToEveryTextAndImageForm() {
        let targets = ConversionFormat.available(for: .pdf)
        for expected in [ConversionFormat.markdown, .plainText, .richText, .html, .pngPages] {
            XCTAssertTrue(targets.contains(expected), "PDF should convert to \(expected.label)")
        }
    }

    func testEverythingElseOnlyGoesToPDF() {
        for family in [SourceFamily.markdown, .html, .image, .wordProcessing] {
            XCTAssertEqual(ConversionFormat.available(for: family), [.pdf], "\(family)")
        }
    }

    func testNoSourcesOffersNoTargets() {
        XCTAssertEqual(ConversionFormat.available(forSources: []), [])
    }

    func testALonePDFIsNotOfferedPDF() {
        // Converting a PDF to a PDF is not something anyone asks for; it is
        // only reachable so a mixed batch can be normalised.
        XCTAssertFalse(ConversionFormat.available(forSources: [.pdf]).contains(.pdf))
    }

    func testMixedBatchNormalisesToPDF() {
        XCTAssertEqual(ConversionFormat.available(forSources: [.pdf, .markdown]), [.pdf])
        XCTAssertEqual(ConversionFormat.available(forSources: [.markdown, .image]), [.pdf])
    }
}

final class ConversionFormatMetadataTests: XCTestCase {
    func testFileExtensions() {
        XCTAssertEqual(ConversionFormat.pdf.fileExtension, "pdf")
        XCTAssertEqual(ConversionFormat.markdown.fileExtension, "md")
        XCTAssertEqual(ConversionFormat.plainText.fileExtension, "txt")
        XCTAssertEqual(ConversionFormat.richText.fileExtension, "rtf")
        XCTAssertEqual(ConversionFormat.html.fileExtension, "html")
    }

    func testOnlyPNGProducesADirectory() {
        for format in ConversionFormat.allCases {
            XCTAssertEqual(format.producesDirectory, format == .pngPages, format.label)
        }
    }

    func testEveryFormatIsLabelled() {
        for format in ConversionFormat.allCases {
            XCTAssertFalse(format.label.isEmpty)
        }
    }
}

@MainActor
final class OutputNamingTests: XCTestCase {
    private var scratch = Scratch()

    override func setUp() {
        super.setUp()
        scratch = Scratch()
    }

    func testKeepsStemAndSwapsExtension() {
        let source = URL(fileURLWithPath: "/docs/Report Q3.md")
        XCTAssertEqual(Converter.outputName(for: source, format: .pdf), "Report Q3.pdf")
    }

    func testOnlyTheFinalExtensionIsReplaced() {
        let source = URL(fileURLWithPath: "/docs/a.b.c.md")
        XCTAssertEqual(Converter.outputName(for: source, format: .pdf), "a.b.c.pdf")
    }

    func testImageOutputNamesAFolder() {
        let source = URL(fileURLWithPath: "/docs/Report.pdf")
        XCTAssertEqual(Converter.outputName(for: source, format: .pngPages), "Report pages")
    }

    func testUnusedPathIsReturnedUnchanged() {
        let free = scratch.path("nothing-here.pdf")
        XCTAssertEqual(Converter.vacantDestination(free), free)
    }

    func testExistingFileIsSteppedAround() {
        let taken = scratch.file("taken.pdf", "x")
        let next = Converter.vacantDestination(taken)
        XCTAssertEqual(next.lastPathComponent, "taken 2.pdf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: next.path),
                       "the suggested path must actually be free")
    }

    func testItKeepsSteppingUntilFree() {
        let taken = scratch.file("taken.pdf", "x")
        scratch.file("taken 2.pdf", "x")
        XCTAssertEqual(Converter.vacantDestination(taken).lastPathComponent, "taken 3.pdf")
    }

    func testDirectoryNamesStepWithoutGainingAnExtension() {
        let folder = scratch.path("pages")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertEqual(Converter.vacantDestination(folder).lastPathComponent, "pages 2")
    }
}
