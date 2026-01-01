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

            ProjectCommands()
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
    }
}

// MARK: - Project Commands

struct ProjectCommands: Commands {
    @FocusedValue(\.projectDocument) var projectDocument

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button("Save Project") {
                saveProject()
            }
            .keyboardShortcut("s")
            .disabled(projectDocument == nil)

            Button("Save Project As...") {
                saveProjectAs()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(projectDocument == nil)
        }
    }

    private func saveProject() {
        guard let document = projectDocument else { return }
        if document.fileURL != nil {
            do {
                try document.save()
            } catch {
                print("Save error: \(error)")
            }
        } else {
            saveProjectAs()
        }
    }

    private func saveProjectAs() {
        guard let document = projectDocument else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "projector")!]
        panel.nameFieldStringValue = "Untitled.projector"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try document.save(to: url)
            } catch {
                print("Save error: \(error)")
            }
        }
    }
}

// MARK: - Focused Values

struct ProjectDocumentKey: FocusedValueKey {
    typealias Value = ProjectDocument
}

extension FocusedValues {
    var projectDocument: ProjectDocument? {
        get { self[ProjectDocumentKey.self] }
        set { self[ProjectDocumentKey.self] = newValue }
    }
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
