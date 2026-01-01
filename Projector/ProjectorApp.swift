import SwiftUI
import UniformTypeIdentifiers

@main
struct ProjectorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            ProjectCommands()
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
    }
}

// MARK: - Project Commands

struct ProjectCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button("Save Project") {
                if let delegate = NSApp.delegate as? AppDelegate {
                    delegate.saveProject(nil)
                }
            }
            .keyboardShortcut("s", modifiers: .command)

            Button("Save Project As...") {
                if let delegate = NSApp.delegate as? AppDelegate {
                    delegate.saveProjectAs(nil)
                }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
        }
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Setup notification observer for file open
        NotificationCenter.default.addObserver(
            forName: .openFile,
            object: nil,
            queue: .main
        ) { _ in
            self.openFile()
        }
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
