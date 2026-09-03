import SwiftUI

struct FolioCommands: Commands {
    @State private var state = AppState.shared
    @State private var prefs = Prefs.shared
    @State private var recents = Recents.shared

    var body: some Commands {
        // MARK: File

        CommandGroup(replacing: .newItem) {
            Button("Open…") { state.showOpenFilePanel() }
                .keyboardShortcut("o")

            Button("Open Folder…") { state.showOpenFolderPanel() }
                .keyboardShortcut("o", modifiers: [.command, .shift])

            Menu("Open Recent") {
                if recents.items.isEmpty {
                    Text("No recent documents")
                } else {
                    ForEach(recents.items.prefix(16), id: \.path) { url in
                        Button(url.lastPathComponent) { state.open(url) }
                    }
                    Divider()
                    Button("Clear Menu") { recents.clear() }
                }
            }
        }

        CommandGroup(after: .newItem) {
            Divider()
            Button("Close Tab") { state.closeCurrent() }
                .keyboardShortcut("w")
                .disabled(state.current == nil)
            Button("Reload from Disk") { state.send(.reload) }
                .keyboardShortcut("r")
                .disabled(state.current == nil)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") { state.send(.save) }
                .keyboardShortcut("s")
                .disabled(state.current?.hasUnsavedChanges != true)

            Button("Export as PDF…") { state.exportCurrentAsPDF() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(state.current == nil)

            Button("Convert…") { state.showConverter() }
                .keyboardShortcut("k", modifiers: [.command, .shift])

            Divider()

            Button("Reveal in Finder") { state.send(.revealInFinder) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(state.current == nil)
        }

        CommandGroup(replacing: .printItem) {
            Button("Print…") { state.send(.printDocument) }
                .keyboardShortcut("p")
                .disabled(state.current == nil)
        }

        // MARK: Edit / Find

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find…") {
                state.isFindBarVisible = true
            }
            .keyboardShortcut("f")
            .disabled(state.current == nil)

            Button("Find Next") { state.send(.findNext) }
                .keyboardShortcut("g")
                .disabled(state.current == nil)

            Button("Find Previous") { state.send(.findPrevious) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(state.current == nil)

            Divider()

            Button("Highlight Selection") { state.send(.highlightSelection) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(state.current?.kind != .pdf)
        }

        // MARK: View

        CommandGroup(after: .sidebar) {
            Divider()

            Picker("Sidebar Shows", selection: $state.sidebarMode) {
                Text("Files").tag(SidebarMode.files)
                Text("Outline").tag(SidebarMode.outline)
                Text("Pages").tag(SidebarMode.thumbnails)
            }

            Divider()

            Button("Zoom In") { state.send(.zoomIn) }
                .keyboardShortcut("+")
                .disabled(state.current == nil)
            Button("Zoom Out") { state.send(.zoomOut) }
                .keyboardShortcut("-")
                .disabled(state.current == nil)
            Button("Actual Size") { state.send(.zoomActualSize) }
                .keyboardShortcut("0")
                .disabled(state.current == nil)
            Button("Fit to Window") { state.send(.zoomToFit) }
                .keyboardShortcut("9")
                .disabled(state.current?.kind != .pdf)

            Divider()

            Picker("Appearance", selection: $prefs.theme) {
                ForEach(AppTheme.allCases) { Text($0.label).tag($0) }
            }

            Toggle("Full Width", isOn: $prefs.wideContent)
            Toggle("Two-Page PDF View", isOn: $prefs.twoUp)
        }

        // MARK: Go

        CommandMenu("Go") {
            Button("Next Page") { state.send(.nextPage) }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(state.current?.kind != .pdf)
            Button("Previous Page") { state.send(.previousPage) }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(state.current?.kind != .pdf)
            Button("First Page") { state.send(.firstPage) }
                .disabled(state.current?.kind != .pdf)
            Button("Last Page") { state.send(.lastPage) }
                .disabled(state.current?.kind != .pdf)
            Button("Go to Page…") { state.isGoToPageVisible = true }
                .keyboardShortcut("g", modifiers: [.command, .option])
                .disabled(state.current?.kind != .pdf)

            Divider()

            Button("Rotate Left") { state.send(.rotateLeft) }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(state.current?.kind != .pdf)
            Button("Rotate Right") { state.send(.rotateRight) }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(state.current?.kind != .pdf)

            Divider()

            Button("Next Tab") { state.selectTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(state.tabs.count < 2)
            Button("Previous Tab") { state.selectTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(state.tabs.count < 2)

            Divider()

            ForEach(1...9, id: \.self) { number in
                Button("Tab \(number)") { state.selectTab(at: number - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                    .disabled(state.tabs.count < number)
            }
        }

        CommandGroup(replacing: .help) {
            Button("Folio Help") {
                if let readme = Bundle.main.url(forResource: "README", withExtension: "md") {
                    AppState.shared.open(readme)
                }
            }
        }
    }
}
