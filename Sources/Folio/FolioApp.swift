import AppKit
import SwiftUI

@main
struct FolioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState.shared
    @State private var prefs = Prefs.shared

    var body: some Scene {
        Window("Folio", id: "main") {
            RootView()
                .environment(state)
                .environment(prefs)
                .preferredColorScheme(prefs.theme.colorScheme)
                .frame(minWidth: 720, minHeight: 460)
        }
        .defaultSize(width: 1180, height: 820)
        .commands { FolioCommands() }

        Settings {
            PrefsView()
                .environment(prefs)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Files handed over by Finder ("Open With", double-click, drag onto the icon).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { AppState.shared.open(url) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // ⌘W closes the current tab, so the window's own Close moves to ⇧⌘W,
        // matching how browsers and other tabbed readers behave.
        DispatchQueue.main.async {
            guard let fileMenu = NSApp.mainMenu?.items
                .first(where: { $0.submenu?.items.contains(where: { $0.action == #selector(NSWindow.performClose(_:)) }) == true })?
                .submenu
            else { return }
            for item in fileMenu.items where item.action == #selector(NSWindow.performClose(_:)) {
                item.keyEquivalentModifierMask = [.command, .shift]
                item.title = "Close Window"
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        for tab in AppState.shared.tabs { tab.stopWatching() }
    }
}
