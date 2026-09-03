import SwiftUI

struct FindBar: View {
    @Environment(AppState.self) private var state
    @FocusState private var isFocused: Bool

    var body: some View {
        if let document = state.current {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))

                TextField("Find in document", text: Binding(
                    get: { document.searchQuery },
                    set: { document.searchQuery = $0 }
                ))
                .textFieldStyle(.plain)
                .frame(width: 200)
                .focused($isFocused)
                .onSubmit { state.send(.findNext) }

                if document.isSearching {
                    ProgressView().controlSize(.small)
                } else {
                    Text(resultLabel(for: document))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(document.matchCount == 0 && !document.searchQuery.isEmpty
                                         ? .red : .secondary)
                        .frame(minWidth: 60, alignment: .trailing)
                }

                Divider().frame(height: 14)

                Button { state.send(.findPrevious) } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)
                .disabled(document.searchQuery.isEmpty)
                .help("Previous match (⇧⌘G)")

                Button { state.send(.findNext) } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.plain)
                .disabled(document.searchQuery.isEmpty)
                .help("Next match (⌘G)")

                Button {
                    state.send(.endFind)
                    state.isFindBarVisible = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close find bar")
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            .shadow(radius: 8, y: 2)
            .onAppear { isFocused = true }
            // Debounced so each keystroke does not restart a full-document scan.
            .task(id: document.searchQuery) {
                let query = document.searchQuery
                guard !query.isEmpty else {
                    state.send(.endFind)
                    return
                }
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled else { return }
                state.send(.find(query))
            }
        }
    }

    /// PDFKit reports a real match count; WebKit's find API reports only
    /// whether something matched, which `-1` stands for.
    private func resultLabel(for document: OpenDocument) -> String {
        if document.searchQuery.isEmpty { return "" }
        if document.matchCount < 0 { return "Found" }
        if document.matchCount == 0 { return "No results" }
        if document.kind == .pdf { return "\(document.matchIndex) of \(document.matchCount)" }
        return "\(document.matchCount)"
    }
}
