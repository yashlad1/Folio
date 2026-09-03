import Foundation

/// Watches one file for content changes and calls back on the main queue.
///
/// This polls `stat` rather than using a vnode source: editors save markdown
/// both in place and by atomic rename, and a single vnode source on the file
/// misses the rename case while a source on the directory misses in-place
/// writes. One `stat` every 600 ms is cheaper than getting that wrong.
final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void
    private let timer: DispatchSourceTimer
    private var signature: Signature?

    private struct Signature: Equatable {
        let size: Int
        let modified: Date
    }

    init(url: URL, interval: TimeInterval = 0.6, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        self.signature = Self.read(url)

        timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
    }

    private func tick() {
        let current = Self.read(url)
        guard current != signature else { return }
        signature = current
        // A missing file usually means a save is mid-flight; wait for the next tick.
        guard current != nil else { return }
        DispatchQueue.main.async { [weak self] in self?.onChange() }
    }

    private static func read(_ url: URL) -> Signature? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize,
              let modified = values.contentModificationDate
        else { return nil }
        return Signature(size: size, modified: modified)
    }

    func cancel() { timer.cancel() }

    deinit { timer.cancel() }
}
