import SwiftUI

/// In-app document tabs. Folio uses one window with its own tab strip rather
/// than macOS window tabs, so the sidebar and toolbar stay shared.
struct TabStrip: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(state.tabs.enumerated()), id: \.element.id) { index, document in
                        TabItem(document: document, index: index)
                            .id(document.id)
                        Divider().frame(height: 16)
                    }
                }
            }
            .frame(height: 30)
            .background(.bar)
            .onChange(of: state.selectedTabID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { scroller.scrollTo(id) }
            }
        }
    }
}

private struct TabItem: View {
    @Environment(AppState.self) private var state
    let document: OpenDocument
    let index: Int

    @State private var isHovering = false

    private var isSelected: Bool { document.id == state.selectedTabID }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: document.kind.symbol)
                .font(.system(size: 10))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)

            Text(document.title)
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)

            if document.hasUnsavedChanges {
                Circle()
                    .fill(.orange)
                    .frame(width: 5, height: 5)
            }

            // The close control only takes space once it can be clicked.
            Button {
                state.close(document)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 13, height: 13)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isHovering || isSelected ? 1 : 0)
            .help("Close tab (⌘W)")
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .frame(maxWidth: 210)
        .background(isSelected ? Color(nsColor: .controlBackgroundColor) : .clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isSelected ? Color.accentColor : .clear)
                .frame(height: 2)
        }
        .contentShape(Rectangle())
        .onTapGesture { state.selectedTabID = document.id }
        .onHover { isHovering = $0 }
        .help(document.url.path)
        .contextMenu {
            Button("Close") { state.close(document) }
            Button("Close Others") { state.closeOthers(than: document) }
            Divider()
            Button("Reveal in Finder") { state.revealInFinder(document) }
            Button("Reload from Disk") { document.controller?.perform(.reload) }
        }
    }
}
