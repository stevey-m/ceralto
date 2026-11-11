import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, ObservableObject {
    init() { super.init(window: nil) }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    func show(store: NotesStore, preferences: UserDefaults = .standard, section: SettingsSection = .general) {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            let host = NSHostingController(rootView: SettingsView(section: section)
                .environmentObject(store).defaultAppStorage(preferences))
            // AppKit owns resize constraints; SwiftUI must not reset them after layout.
            host.sizingOptions = []
            window.contentViewController = host
            window.title = "Ceralto Settings"
            window.identifier = NSUserInterfaceItemIdentifier("deltos-settings")
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 720, height: 480)
            window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                           height: CGFloat.greatestFiniteMagnitude)
            window.center()
            window.setFrameAutosaveName("DeltosSettingsWindow")
            self.window = window
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
