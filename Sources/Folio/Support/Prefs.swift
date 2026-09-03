import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum ReadingFont: String, CaseIterable, Identifiable {
    case sans, serif, mono

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sans: return "Sans"
        case .serif: return "Serif"
        case .mono: return "Mono"
        }
    }
}

/// User preferences, persisted to `UserDefaults` on every mutation.
@Observable
final class Prefs {
    static let shared = Prefs()

    private enum Key {
        static let theme = "theme"
        static let fontSize = "markdownFontSize"
        static let readingFont = "readingFont"
        static let wideContent = "wideContent"
        static let lineNumbers = "codeLineNumbers"
        static let lastPages = "pdfLastPages"
        static let twoUp = "pdfTwoUp"
    }

    private let store = UserDefaults.standard

    var theme: AppTheme { didSet { store.set(theme.rawValue, forKey: Key.theme) } }
    var fontSize: Double { didSet { store.set(fontSize, forKey: Key.fontSize) } }
    var readingFont: ReadingFont { didSet { store.set(readingFont.rawValue, forKey: Key.readingFont) } }
    var wideContent: Bool { didSet { store.set(wideContent, forKey: Key.wideContent) } }
    var codeLineNumbers: Bool { didSet { store.set(codeLineNumbers, forKey: Key.lineNumbers) } }
    var twoUp: Bool { didSet { store.set(twoUp, forKey: Key.twoUp) } }

    private var lastPages: [String: Int] { didSet { store.set(lastPages, forKey: Key.lastPages) } }

    private init() {
        theme = AppTheme(rawValue: store.string(forKey: Key.theme) ?? "") ?? .system
        let size = store.double(forKey: Key.fontSize)
        fontSize = size >= 10 ? size : 16
        readingFont = ReadingFont(rawValue: store.string(forKey: Key.readingFont) ?? "") ?? .sans
        wideContent = store.bool(forKey: Key.wideContent)
        codeLineNumbers = store.object(forKey: Key.lineNumbers) as? Bool ?? true
        twoUp = store.bool(forKey: Key.twoUp)
        lastPages = store.dictionary(forKey: Key.lastPages) as? [String: Int] ?? [:]
    }

    // MARK: Per-document reading position

    func lastPage(for url: URL) -> Int? { lastPages[url.path] }

    func setLastPage(_ page: Int, for url: URL) {
        guard lastPages[url.path] != page else { return }
        if lastPages.count > 500, let oldest = lastPages.keys.first { lastPages[oldest] = nil }
        lastPages[url.path] = page
    }

    // MARK: Font size steps

    func zoomText(by delta: Double) {
        fontSize = min(40, max(10, (fontSize + delta).rounded()))
    }

    func resetTextZoom() { fontSize = 16 }
}
