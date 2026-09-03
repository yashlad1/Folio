import Foundation

/// A node in the sidebar's folder tree. Folders that contain no viewable
/// document are pruned, so the sidebar shows only what Folio can open.
final class FileNode: Identifiable, Hashable {
    let id: String
    let url: URL
    let isDirectory: Bool
    let name: String
    var children: [FileNode]?

    init(url: URL, isDirectory: Bool, children: [FileNode]? = nil) {
        self.url = url
        self.id = url.path
        self.isDirectory = isDirectory
        self.name = url.lastPathComponent
        self.children = children
    }

    static func == (lhs: FileNode, rhs: FileNode) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum FileTree {
    /// Directory names never worth walking in a notes or project folder.
    private static let skippedDirectories: Set<String> = [
        "node_modules", ".git", ".svn", ".hg", "venv", ".venv", "env",
        "__pycache__", ".build", "build", "dist", ".next", "target",
        ".tox", ".mypy_cache", ".pytest_cache", ".ruff_cache", ".DS_Store",
        "Pods", ".gradle", ".idea", ".vscode", "site-packages",
    ]

    private static let maxDepth = 8
    private static let maxNodes = 20_000

    /// Builds the tree rooted at `url`, off the main thread by preference.
    static func build(root url: URL) -> FileNode {
        var budget = maxNodes
        let children = walk(url, depth: 0, budget: &budget)
        return FileNode(url: url.standardizedFileURL, isDirectory: true, children: children)
    }

    private static func walk(_ directory: URL, depth: Int, budget: inout Int) -> [FileNode] {
        guard depth < maxDepth, budget > 0 else { return [] }

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )) ?? []

        var folders: [FileNode] = []
        var files: [FileNode] = []

        for item in contents {
            guard budget > 0 else { break }
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

            if isDirectory {
                guard !skippedDirectories.contains(item.lastPathComponent) else { continue }
                let nested = walk(item, depth: depth + 1, budget: &budget)
                // Prune branches with nothing viewable in them.
                guard !nested.isEmpty else { continue }
                budget -= 1
                folders.append(FileNode(url: item, isDirectory: true, children: nested))
            } else {
                guard DocKind.of(item) != nil else { continue }
                budget -= 1
                files.append(FileNode(url: item, isDirectory: false))
            }
        }

        let byName: (FileNode, FileNode) -> Bool = {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return folders.sorted(by: byName) + files.sorted(by: byName)
    }

    /// Depth-first search for a file whose name matches a wiki-style link
    /// target, e.g. `[[Design Notes]]` -> `Design Notes.md`.
    static func findByBasename(_ needle: String, in node: FileNode) -> URL? {
        let target = needle.lowercased()
        var stack = [node]
        while let current = stack.popLast() {
            if !current.isDirectory {
                let base = current.url.deletingPathExtension().lastPathComponent.lowercased()
                if base == target || current.name.lowercased() == target { return current.url }
            }
            stack.append(contentsOf: current.children ?? [])
        }
        return nil
    }
}
