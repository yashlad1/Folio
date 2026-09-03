import Foundation

/// A minimal test harness.
///
/// Folio builds against the Command Line Tools, which ship neither XCTest nor
/// swift-testing, so `swift test` cannot run here. Rather than commit tests
/// that have never been executed, the suite is a plain executable compiled
/// against the real sources by `Scripts/test.sh`.
enum T {
    static var passed = 0
    static var failures: [String] = []
    private static var suiteName = ""

    static func suite(_ name: String) {
        suiteName = name
        print("\n\u{001B}[1m\(name)\u{001B}[0m")
    }

    static func check(_ ok: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
        if ok {
            passed += 1
            print("  \u{001B}[32m✓\u{001B}[0m \(label)")
        } else {
            let extra = detail()
            let line = "\(suiteName) › \(label)" + (extra.isEmpty ? "" : " — \(extra)")
            failures.append(line)
            print("  \u{001B}[31m✗\u{001B}[0m \(label)" + (extra.isEmpty ? "" : " — \(extra)"))
        }
    }

    static func equal<V: Equatable>(_ actual: V, _ expected: V, _ label: String) {
        check(actual == expected, label, "got \(actual), expected \(expected)")
    }

    static func contains(_ haystack: String, _ needle: String, _ label: String) {
        check(haystack.contains(needle), label, "\(needle.debugDescription) missing from \(haystack.prefix(120).debugDescription)")
    }

    static func throwsError(_ label: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            check(false, label, "expected an error, none thrown")
        } catch {
            check(true, label)
        }
    }

    static func report() -> Int32 {
        print("\n" + String(repeating: "─", count: 60))
        if failures.isEmpty {
            print("\u{001B}[32m\(passed) passed, 0 failed\u{001B}[0m")
            return 0
        }
        print("\u{001B}[31m\(passed) passed, \(failures.count) failed\u{001B}[0m")
        for failure in failures { print("  • \(failure)") }
        return 1
    }
}

/// A scratch directory that cleans up after itself.
enum Scratch {
    static let root: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func file(_ name: String, _ contents: String) -> URL {
        let url = root.appendingPathComponent(name)
        try? contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func path(_ name: String) -> URL { root.appendingPathComponent(name) }

    static func removeAll() { try? FileManager.default.removeItem(at: root) }
}
