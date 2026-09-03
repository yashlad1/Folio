import Foundation

/// Recently opened documents and folders, most recent first.
@Observable
final class Recents {
    static let shared = Recents()

    private let store = UserDefaults.standard
    private let key = "recentPaths"
    private let limit = 24

    var items: [URL] { didSet { store.set(items.map(\.path), forKey: key) } }

    private init() {
        let paths = store.stringArray(forKey: key) ?? []
        items = paths.map { URL(fileURLWithPath: $0) }
    }

    func remember(_ url: URL) {
        let clean = url.standardizedFileURL
        items.removeAll { $0.standardizedFileURL == clean }
        items.insert(clean, at: 0)
        if items.count > limit { items = Array(items.prefix(limit)) }
    }

    func forget(_ url: URL) {
        items.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
    }

    /// Drops entries whose file no longer exists.
    func prune() {
        items = items.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func clear() { items = [] }
}
