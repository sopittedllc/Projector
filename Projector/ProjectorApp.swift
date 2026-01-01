import SwiftUI
import UniformTypeIdentifiers

@main
struct ProjectorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenus()

        // Setup notification observer for file open
        NotificationCenter.default.addObserver(
            forName: .openFile,
            object: nil,
            queue: .main
        ) { _ in
            self.openFile()
        }
    }

    private func setupMenus() {
        // Find the File menu
        guard let mainMenu = NSApp.mainMenu,
              let fileMenuItem = mainMenu.item(withTitle: "File"),
              let fileMenu = fileMenuItem.submenu else { return }

        // Remove existing Save items if any
        fileMenu.items.removeAll { $0.title.contains("Save") || $0.title == "Close" }

        // Add Save Project
        let saveItem = NSMenuItem(
            title: "Save Project",
            action: #selector(saveProject(_:)),
            keyEquivalent: "s"
        )
        saveItem.target = self
        fileMenu.insertItem(saveItem, at: 0)

        // Add Save Project As
        let saveAsItem = NSMenuItem(
            title: "Save Project As...",
            action: #selector(saveProjectAs(_:)),
            keyEquivalent: "S"
        )
        saveAsItem.keyEquivalentModifierMask = [.command, .shift]
        saveAsItem.target = self
        fileMenu.insertItem(saveAsItem, at: 1)

        // Add separator
        fileMenu.insertItem(NSMenuItem.separator(), at: 2)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // MARK: - Save Actions (called via selector from menu commands)

    @objc func saveProject(_ sender: Any?) {
        NotificationCenter.default.post(name: .saveProject, object: nil)
    }

    @objc func saveProjectAs(_ sender: Any?) {
        NotificationCenter.default.post(name: .saveProjectAs, object: nil)
    }

    // MARK: - Open Action

    private func openFile() {
        guard let window = NSApp.mainWindow else { return }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]

        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url {
                NotificationCenter.default.post(name: .videoFileSelected, object: url)
            }
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let openFile = Notification.Name("openFile")
    static let videoFileSelected = Notification.Name("videoFileSelected")
    static let saveProject = Notification.Name("saveProject")
    static let saveProjectAs = Notification.Name("saveProjectAs")
}
