import WebKit
import XCTest
@testable import Folio

/// The guard that keeps a conversion from reaching the network.
///
/// These are regression tests for a real failure: the rule list was originally
/// written with an alternation (`^(folio|file|…):`), which WebKit's
/// content-blocker engine rejects. Compilation failed, the guard was never
/// installed, and conversion silently went back to fetching remote resources.
@MainActor
final class OfflineGuardTests: XCTestCase {
    func testRuleListIsValidJSON() throws {
        let parsed = try JSONSerialization.jsonObject(
            with: Data(OffscreenRenderer.blockRules.utf8)
        ) as? [[String: Any]]
        XCTAssertGreaterThanOrEqual(parsed?.count ?? 0, 2, "a block rule plus allow rules")
    }

    func testUsesNoAlternation() {
        XCTAssertFalse(
            OffscreenRenderer.blockRules.contains("|"),
            "WebKit's content-blocker regex rejects alternation, which disarms the guard silently"
        )
    }

    func testBlocksEverythingThenReadmitsLocalSchemes() {
        let rules = OffscreenRenderer.blockRules
        assertContains(rules, "\"block\"", "there is a catch-all block rule")
        for scheme in ["folio", "file", "data", "blob", "about"] {
            assertContains(rules, "^\(scheme):", "\(scheme): is re-admitted")
        }
    }

    func testNoRemoteSchemeIsReadmitted() {
        for scheme in ["http", "https", "ws", "wss", "ftp"] {
            XCTAssertFalse(
                OffscreenRenderer.blockRules.contains("^\(scheme):"),
                "\(scheme): must never be allowed"
            )
        }
    }

    /// The check that actually matters: WebKit has to accept the list.
    func testWebKitCompilesTheRuleList() async throws {
        let compiled: WKContentRuleList? = await withCheckedContinuation { continuation in
            WKContentRuleListStore.default()?.compileContentRuleList(
                forIdentifier: "folio-test-guard",
                encodedContentRuleList: OffscreenRenderer.blockRules
            ) { list, _ in continuation.resume(returning: list) }
        }
        XCTAssertNotNil(compiled, "WebKit must compile the rule list, or the guard is not installed")
    }
}
