import Foundation

/// One entry in a document's table of contents. Flat with an explicit `level`
/// so markdown headings and PDF bookmarks share a single renderer.
struct OutlineItem: Identifiable, Hashable {
    let id: String
    let title: String
    /// 1-based nesting depth.
    let level: Int
    /// Markdown target: the DOM element id to scroll to.
    var anchor: String?
    /// PDF target: the zero-based page index.
    var pageIndex: Int?
}
