import SwiftUI

@main
struct ProjectorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open...") {
                    NotificationCenter.default.post(name: .openFile, object: nil)
                }
                .keyboardShortcut("o")
            }

            ProjectSaveCommands()
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
    }
}

// MARK: - Save Commands

struct ProjectSaveCommands: Commands {
    @FocusedValue(\.saveProjectAction) var saveAction
    @FocusedValue(\.saveProjectAsAction) var saveAsAction

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button("Save Project") {
                saveAction?()
            }
            .keyboardShortcut("s")
            .disabled(saveAction == nil)

            Button("Save Project As...") {
                saveAsAction?()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(saveAsAction == nil)
        }
    }
}

// MARK: - Focused Values

extension FocusedValues {
    @Entry var saveProjectAction: (() -> Void)? = nil
    @Entry var saveProjectAsAction: (() -> Void)? = nil
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
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
}
