import AppKit

// Folio's conversion pipeline leans on WebKit and TextKit, both of which need a
// running app and a live run loop. The suite therefore boots a faceless
// NSApplication and runs inside it rather than as a bare command-line process.

@MainActor
func runAllTests() async {
    // Pure logic, no app services needed.
    testDocKind()
    testSourceFamily()
    testConversionAvailability()
    testFormatMetadata()
    testOutputNaming()
    testVacantDestination()
    testMarkdownRendering()
    testMarkdownEscaping()
    testPlainTextRendering()
    testHTMLRendering()
    testAttributedRendering()
    await testOfflineGuardRules()

    // End to end, over real files.
    await testImageToPDF()
    await testWordProcessingToPDF()
    await testMarkdownToPDF()
    await testLongMarkdownPaginates()
    await testPDFRoundTrip()
    await testPDFStructureRecovery()
    await testPDFToImages()
    await testRejectsUnsupported()
    await testPDFPassThrough()
}

final class TestHost: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            await runAllTests()
            let status = T.report()
            Scratch.removeAll()
            exit(status)
        }
    }
}

setvbuf(stdout, nil, _IONBF, 0)
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let host = TestHost()
application.delegate = host
application.run()
