import Foundation

/// Imperative actions a menu command or toolbar button sends to whichever
/// view is currently showing a document.
enum DocAction {
    case zoomIn
    case zoomOut
    case zoomActualSize
    case zoomToFit

    case find(String)
    case findNext
    case findPrevious
    case endFind

    case goToPage(Int)
    case nextPage
    case previousPage
    case firstPage
    case lastPage

    case rotateLeft
    case rotateRight
    case setTwoUp(Bool)

    case scrollTo(anchor: String)
    case copySelection
    case highlightSelection
    case selectAll

    case reload
    case themeChanged
    case typographyChanged
    case save
    case exportPDF(URL)
    case printDocument
    case revealInFinder
}

/// Implemented by the coordinator of each document view.
protocol DocumentController: AnyObject {
    func perform(_ action: DocAction)
    /// True when the document has unsaved edits (PDF annotations).
    var isEditable: Bool { get }
}
