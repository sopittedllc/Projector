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
            CommandGroup(replacing: .newItem) {
                Button("Open...") {
                    NotificationCenter.default.post(name: .openFile, object: nil)
                }
                .keyboardShortcut("o")
            }

            CommandGroup(replacing: .saveItem) {
                Button("Save Project") {
                    NSApp.sendAction(#selector(AppCommands.saveProject), to: nil, from: nil)
                }
                .keyboardShortcut("s")

                Button("Save Project As...") {
                    NSApp.sendAction(#selector(AppCommands.saveProjectAs), to: nil, from: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
    }
}

// MARK: - App Commands Protocol

@objc protocol AppCommands {
    func saveProject()
    func saveProjectAs()
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
