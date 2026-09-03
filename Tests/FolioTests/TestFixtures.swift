import AppKit
import Foundation
import PDFKit
import XCTest

/// A scratch directory scoped to one test case.
///
/// Fixtures are generated rather than committed: the suite stays free of binary
/// files, and a fixture cannot drift out of step with what the code produces.
final class Scratch {
    let root: URL

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func path(_ name: String) -> URL { root.appendingPathComponent(name) }

    @discardableResult
    func file(_ name: String, _ contents: String) -> URL {
        let url = path(name)
        try? contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func png(_ name: String, side: CGFloat = 120) -> URL {
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSColor.systemIndigo.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: side, height: side)).fill()
        image.unlockFocus()

        let url = path(name)
        if let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let data = bitmap.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
        }
        return url
    }

    func rtf(_ name: String, text: String) -> URL {
        let attributed = NSAttributedString(
            string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)]
        )
        let url = path(name)
        if let data = try? attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) {
            try? data.write(to: url)
        }
        return url
    }
}

// MARK: - Reading results back

/// The text layer of a PDF.
///
/// Assertions go through this rather than file size on purpose: a blank page is
/// the characteristic failure of the export path, and it is invisible in the
/// byte count.
func pdfText(_ url: URL) -> String {
    guard let document = PDFDocument(url: url) else { return "" }
    return (0..<document.pageCount)
        .compactMap { document.page(at: $0)?.string }
        .joined(separator: "\n")
}

func pdfPageCount(_ url: URL) -> Int {
    PDFDocument(url: url)?.pageCount ?? 0
}

func fileSize(_ url: URL) -> Int {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int ?? 0
}

extension XCTestCase {
    func assertContains(
        _ haystack: String, _ needle: String, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(
            haystack.contains(needle),
            "\(message) — \(needle.debugDescription) missing from \(haystack.prefix(160).debugDescription)",
            file: file, line: line
        )
    }
}
