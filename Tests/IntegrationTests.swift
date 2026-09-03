import AppKit
import Foundation
import PDFKit

// Fixtures are generated rather than committed, so the suite carries no binary
// files and cannot drift from what the code actually produces.

private func makePNG(_ name: String, size: CGFloat = 120) -> URL {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    NSColor.systemIndigo.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()
    image.unlockFocus()

    let url = Scratch.path(name)
    if let tiff = image.tiffRepresentation,
       let bitmap = NSBitmapImageRep(data: tiff),
       let png = bitmap.representation(using: .png, properties: [:]) {
        try? png.write(to: url)
    }
    return url
}

private func makeRTF(_ name: String, text: String) -> URL {
    let attributed = NSAttributedString(
        string: text,
        attributes: [.font: NSFont.systemFont(ofSize: 12)]
    )
    let url = Scratch.path(name)
    if let data = try? attributed.data(
        from: NSRange(location: 0, length: attributed.length),
        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
    ) {
        try? data.write(to: url)
    }
    return url
}

private func pdfText(_ url: URL) -> String {
    guard let document = PDFDocument(url: url) else { return "" }
    return (0..<document.pageCount)
        .compactMap { document.page(at: $0)?.string }
        .joined(separator: "\n")
}

private func pageCount(_ url: URL) -> Int {
    PDFDocument(url: url)?.pageCount ?? 0
}

// MARK: - Into PDF

@MainActor
func testImageToPDF() async {
    T.suite("Convert › image to PDF")
    let source = makePNG("square.png")
    let target = Scratch.path("square.pdf")
    do {
        try await Converter.convert(source, to: .pdf, at: target)
        T.check(FileManager.default.fileExists(atPath: target.path), "writes a file")
        T.equal(pageCount(target), 1, "a single-frame image makes one page")
    } catch {
        T.check(false, "converts without error", "\(error)")
    }
}

@MainActor
func testWordProcessingToPDF() async {
    T.suite("Convert › rich text to PDF")
    let source = makeRTF("memo.rtf", text: "Quarterly figures are attached for review.")
    let target = Scratch.path("memo.pdf")
    do {
        try await Converter.convert(source, to: .pdf, at: target)
        T.check(pageCount(target) >= 1, "produces at least one page")
        T.contains(pdfText(target), "Quarterly figures", "the text survives into the PDF")
    } catch {
        T.check(false, "converts without error", "\(error)")
    }
}

@MainActor
func testMarkdownToPDF() async {
    T.suite("Convert › markdown to PDF (full renderer)")
    let source = Scratch.file("note.md", """
    # Release Notes

    A paragraph of prose that is long enough to occupy a line of its own.

    | Key | Value |
    |-----|-------|
    | one | two   |
    """)
    let target = Scratch.path("note.pdf")
    do {
        try await Converter.convert(source, to: .pdf, at: target)
        let text = pdfText(target)
        T.check(pageCount(target) >= 1, "produces at least one page")
        // A blank page is the classic failure here, and it is not visible in
        // the file size — so assert on the text layer.
        T.check(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "the page is not blank")
        T.contains(text, "Release Notes", "the heading renders")
        T.contains(text, "Value", "the table renders")
    } catch {
        T.check(false, "converts without error", "\(error)")
    }
}

@MainActor
func testLongMarkdownPaginates() async {
    T.suite("Convert › pagination")
    var body = "# Long\n\n"
    for index in 1...60 {
        body += "Paragraph number \(index) with enough words to take up a full line of the printed column.\n\n"
    }
    let source = Scratch.file("long.md", body)
    let target = Scratch.path("long.pdf")
    do {
        try await Converter.convert(source, to: .pdf, at: target)
        T.check(pageCount(target) > 1, "a long document spans multiple pages",
                "got \(pageCount(target)) page(s)")
        T.contains(pdfText(target), "Paragraph number 60", "content near the end is not dropped")
    } catch {
        T.check(false, "converts without error", "\(error)")
    }
}

// MARK: - Back out of PDF

@MainActor
func testPDFRoundTrip() async {
    T.suite("Convert › PDF back to text formats")
    let source = Scratch.file("round.md", """
    # Annual Review

    An opening paragraph that runs on for long enough that it will be wrapped across more than one line when it is laid out into a printed column of text.

    ## Details

    A second section with its own body copy, also long enough to wrap onto a further line of the page.
    """)
    let pdf = Scratch.path("round.pdf")
    do {
        try await Converter.convert(source, to: .pdf, at: pdf)
    } catch {
        T.check(false, "prepares a PDF to read back", "\(error)")
        return
    }

    for format in [ConversionFormat.markdown, .plainText, .richText, .html] {
        // Deliberately not "round.<ext>" — that would collide with the source
        // fixture and quietly overwrite it.
        let target = Scratch.path("round-out.\(format.fileExtension)")
        do {
            try await Converter.convert(pdf, to: format, at: target)
            let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size]) as? Int ?? 0
            T.check(size > 0, "\(format.label) output is written and non-empty")
            T.check(FileManager.default.fileExists(atPath: source.path), "the source file is left alone")
        } catch {
            T.check(false, "converts to \(format.label)", "\(error)")
        }
    }
}

@MainActor
func testPDFStructureRecovery() async {
    T.suite("Convert › structure recovered from PDF")
    let source = Scratch.file("structured.md", """
    # Annual Review

    An opening paragraph that runs on for long enough that it will be wrapped across more than one line when it is laid out into the printed column of text on the page.

    ## Details

    - First item in the list
    - Second item in the list
    - Third item in the list
    """)
    let pdf = Scratch.path("structured.pdf")
    let out = Scratch.path("structured-recovered.md")
    do {
        try await Converter.convert(source, to: .pdf, at: pdf)
        try await Converter.convert(pdf, to: .markdown, at: out)
    } catch {
        T.check(false, "round-trips without error", "\(error)")
        return
    }

    let recovered = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
    T.contains(recovered, "# Annual Review", "the top-level heading comes back")
    T.contains(recovered, "## Details", "the second-level heading keeps its level")
    T.check(recovered.contains("- First item in the list"),
            "list items are recovered from their indentation")
    T.check(recovered.contains("wrapped across more than one line when it is laid out"),
            "hard-wrapped lines are rejoined into one paragraph")
}

@MainActor
func testPDFToImages() async {
    T.suite("Convert › PDF to page images")
    let source = Scratch.file("pages.md", "# One\n\ntext\n")
    let pdf = Scratch.path("pages.pdf")
    let folder = Scratch.path("pages-out")
    do {
        try await Converter.convert(source, to: .pdf, at: pdf)
        try await Converter.convert(pdf, to: .pngPages, at: folder)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        T.equal(files.count, pageCount(pdf), "one image per page")
        T.check(files.allSatisfy { $0.hasSuffix(".png") }, "every output is a png")
        T.check(files.contains("page-001.png"), "pages are numbered from one, zero padded")
    } catch {
        T.check(false, "converts without error", "\(error)")
    }
}

@MainActor
func testCodeBlocksAreNotLists() async {
    T.suite("Convert › code is not a list")
    // List recovery keys off indentation, and code blocks are indented too.
    // Monospaced lines are excluded for exactly this reason; if that exclusion
    // regresses, every line of every code sample turns into a bullet.
    let source = Scratch.file("code.md", """
    # Sample

    An ordinary paragraph of prose that is long enough to wrap onto a second line when it is laid out into the printed column.

    ```swift
    struct Folio {
        let bundled = true
    }
    ```
    """)
    let pdf = Scratch.path("code.pdf")
    let out = Scratch.path("code-recovered.md")
    do {
        try await Converter.convert(source, to: .pdf, at: pdf)
        try await Converter.convert(pdf, to: .markdown, at: out)
    } catch {
        T.check(false, "round-trips without error", "\(error)")
        return
    }

    let recovered = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
    let bulletedCode = recovered
        .split(separator: "\n")
        .filter { $0.hasPrefix("- ") && ($0.contains("struct Folio") || $0.contains("bundled")) }
    T.check(bulletedCode.isEmpty, "code lines are not turned into bullets",
            "got \(bulletedCode)")
    T.contains(recovered, "struct Folio", "the code itself is still recovered")
}

// MARK: - Failure handling

@MainActor
func testRejectsUnsupported() async {
    T.suite("Convert › refusals")
    let source = Scratch.file("thing.xyz", "data")
    await T.throwsError("an unknown extension is refused") {
        try await Converter.convert(source, to: .pdf, at: Scratch.path("thing.pdf"))
    }
    await T.throwsError("an unreachable target format is refused") {
        // Markdown cannot be produced from markdown, only from a PDF.
        try await Converter.convert(
            Scratch.file("x.md", "# hi"), to: .markdown, at: Scratch.path("x-out.md")
        )
    }

    let missing = Scratch.path("does-not-exist.png")
    await T.throwsError("a missing source is refused") {
        try await Converter.convert(missing, to: .pdf, at: Scratch.path("missing.pdf"))
    }
}

@MainActor
func testPDFPassThrough() async {
    T.suite("Convert › PDF to PDF")
    let source = Scratch.file("passthrough.md", "# Copy me\n")
    let pdf = Scratch.path("passthrough.pdf")
    let copy = Scratch.path("passthrough-copy.pdf")
    do {
        try await Converter.convert(source, to: .pdf, at: pdf)
        try await Converter.convert(pdf, to: .pdf, at: copy)
        T.equal(pageCount(copy), pageCount(pdf), "a PDF passed to PDF is copied intact")
    } catch {
        T.check(false, "copies without error", "\(error)")
    }
}
