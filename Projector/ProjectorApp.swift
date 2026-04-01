import SwiftUI
import UniformTypeIdentifiers

// MARK: - Custom UTType for .projector files

extension UTType {
    static var projectorProject: UTType {
        UTType(exportedAs: "com.keegandewitt.projector.project")
    }
}

@main
struct ProjectorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
        .handlesExternalEvents(matching: ["projector", "file"])
    }
}


// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSWindowDelegate {
    private var hasSetupMenus = false
    private var hasSetupWindowDelegate = false
    private var activationAttempt = 0
    private let maxActivationAttempts = 6

    /// URL to open when the app finishes launching (for file double-click)
    static var pendingOpenURL: URL?

    /// Tracks if there are unsaved changes (set by ContentView)
    static var hasUnsavedChanges = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        debugPrint("AppDelegate: applicationDidFinishLaunching")

        // DEBUG: Reset welcome overlay flag so it shows on every fresh build
        #if DEBUG
        AppSettings.shared.hasCompletedWelcome = false
        #endif

        // Swizzle NSApplication's sendEvent to intercept CMD+S
        swizzleSendEvent()

        requestInitialActivation()

        // Setup menus after a delay to ensure SwiftUI has created them
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            debugPrint("AppDelegate: delayed setupMenus call")
            self?.setupMenus()
        }

        // Also setup menus when the app becomes active (handles reactivation)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            debugPrint("AppDelegate: didBecomeActive")
            self?.setupMenus()
            self?.setupWindowDelegate()
        }

        // Setup notification observer for file open
        NotificationCenter.default.addObserver(
            forName: .openFile,
            object: nil,
            queue: .main
        ) { _ in
            self.openFile()
        }
    }

    private func requestInitialActivation() {
        activationAttempt = 0
        attemptActivation()
    }

    private func attemptActivation() {
        activationAttempt += 1
        NSApp.activate(ignoringOtherApps: true)
        NSApp.unhide(nil)

        if let window = NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }

        guard activationAttempt < maxActivationAttempts else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.attemptActivation()
        }
    }

    private func swizzleSendEvent() {
        let originalSelector = #selector(NSApplication.sendEvent(_:))
        let swizzledSelector = #selector(NSApplication.projector_sendEvent(_:))

        guard let originalMethod = class_getInstanceMethod(NSApplication.self, originalSelector),
              let swizzledMethod = class_getInstanceMethod(NSApplication.self, swizzledSelector) else {
            debugPrint("Failed to swizzle sendEvent")
            return
        }

        method_exchangeImplementations(originalMethod, swizzledMethod)
        debugPrint("sendEvent swizzled successfully")
    }

    private func setupMenus() {
        guard !hasSetupMenus else {
            debugPrint("setupMenus: already setup")
            return
        }

        // Find the File menu (usually second after App menu)
        guard let mainMenu = NSApp.mainMenu else {
            debugPrint("setupMenus: no mainMenu")
            return
        }

        debugPrint("setupMenus: mainMenu has %d items: %@", mainMenu.items.count, mainMenu.items.map { $0.title })

        guard mainMenu.items.count > 1 else {
            debugPrint("setupMenus: not enough menu items")
            return
        }

        let fileMenuItem = mainMenu.items[1]
        debugPrint("setupMenus: fileMenuItem title: %@", fileMenuItem.title)

        hasSetupMenus = true

        // Create a completely new File menu (prevents SwiftUI from managing it)
        let newFileMenu = NSMenu(title: "File")
        newFileMenu.autoenablesItems = false

        // Save Project
        let saveItem = NSMenuItem(
            title: "Save Project",
            action: #selector(saveProject(_:)),
            keyEquivalent: "s"
        )
        saveItem.target = self
        saveItem.isEnabled = true
        newFileMenu.addItem(saveItem)

        // Save Project As
        let saveAsItem = NSMenuItem(
            title: "Save Project As...",
            action: #selector(saveProjectAs(_:)),
            keyEquivalent: "S"
        )
        saveAsItem.keyEquivalentModifierMask = [.command, .shift]
        saveAsItem.target = self
        saveAsItem.isEnabled = true
        newFileMenu.addItem(saveAsItem)

        newFileMenu.addItem(NSMenuItem.separator())

        // Open Project
        let openItem = NSMenuItem(
            title: "Open Project...",
            action: #selector(openProjectMenu(_:)),
            keyEquivalent: "o"
        )
        openItem.target = self
        openItem.isEnabled = true
        newFileMenu.addItem(openItem)

        newFileMenu.addItem(NSMenuItem.separator())

        // New Window
        let newWindowItem = NSMenuItem(
            title: "New Window",
            action: #selector(NSApplication.newWindowForTab(_:)),
            keyEquivalent: "n"
        )
        newFileMenu.addItem(newWindowItem)

        newFileMenu.addItem(NSMenuItem.separator())

        // Consolidate Media
        let consolidateItem = NSMenuItem(
            title: "Consolidate Media...",
            action: #selector(consolidateMedia(_:)),
            keyEquivalent: ""
        )
        consolidateItem.target = self
        consolidateItem.isEnabled = true
        newFileMenu.addItem(consolidateItem)

        newFileMenu.addItem(NSMenuItem.separator())

        // Close All
        let closeAllItem = NSMenuItem(
            title: "Close All",
            action: #selector(NSWindow.close),
            keyEquivalent: "w"
        )
        closeAllItem.keyEquivalentModifierMask = [.command, .option]
        newFileMenu.addItem(closeAllItem)

        // Replace the submenu entirely
        fileMenuItem.submenu = newFileMenu

        debugPrint("setupMenus: File menu replaced with: %@", newFileMenu.items.map { $0.title })

        // Create Edit menu (insert after File menu)
        let editMenu = NSMenu(title: "Edit")
        editMenu.autoenablesItems = false

        // Undo
        let undoItem = NSMenuItem(
            title: "Undo",
            action: #selector(editUndo(_:)),
            keyEquivalent: "z"
        )
        undoItem.target = self
        undoItem.isEnabled = true
        editMenu.addItem(undoItem)

        // Redo
        let redoItem = NSMenuItem(
            title: "Redo",
            action: #selector(editRedo(_:)),
            keyEquivalent: "Z"
        )
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        redoItem.target = self
        redoItem.isEnabled = true
        editMenu.addItem(redoItem)

        editMenu.addItem(NSMenuItem.separator())

        // Cut
        let cutItem = NSMenuItem(
            title: "Cut",
            action: #selector(editCut(_:)),
            keyEquivalent: "x"
        )
        cutItem.target = self
        cutItem.isEnabled = true
        editMenu.addItem(cutItem)

        // Copy
        let copyItem = NSMenuItem(
            title: "Copy",
            action: #selector(editCopy(_:)),
            keyEquivalent: "c"
        )
        copyItem.target = self
        copyItem.isEnabled = true
        editMenu.addItem(copyItem)

        // Paste
        let pasteItem = NSMenuItem(
            title: "Paste",
            action: #selector(editPaste(_:)),
            keyEquivalent: "v"
        )
        pasteItem.target = self
        pasteItem.isEnabled = true
        editMenu.addItem(pasteItem)

        // Delete
        let deleteItem = NSMenuItem(
            title: "Delete",
            action: #selector(editDelete(_:)),
            keyEquivalent: "\u{8}" // Backspace
        )
        deleteItem.keyEquivalentModifierMask = []
        deleteItem.target = self
        deleteItem.isEnabled = true
        editMenu.addItem(deleteItem)

        editMenu.addItem(NSMenuItem.separator())

        // Select All
        let selectAllItem = NSMenuItem(
            title: "Select All",
            action: #selector(editSelectAll(_:)),
            keyEquivalent: "a"
        )
        selectAllItem.target = self
        selectAllItem.isEnabled = true
        editMenu.addItem(selectAllItem)

        // Deselect All
        let deselectAllItem = NSMenuItem(
            title: "Deselect All",
            action: #selector(editDeselectAll(_:)),
            keyEquivalent: "d"
        )
        deselectAllItem.keyEquivalentModifierMask = [.command, .shift]
        deselectAllItem.target = self
        deselectAllItem.isEnabled = true
        editMenu.addItem(deselectAllItem)

        // Insert Edit menu after File (index 2)
        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editMenuItem.submenu = editMenu

        // Check if Edit menu already exists
        if let existingEditIndex = mainMenu.items.firstIndex(where: { $0.title == "Edit" }) {
            mainMenu.removeItem(at: existingEditIndex)
        }
        mainMenu.insertItem(editMenuItem, at: 2)

        // Create View menu (insert after Edit menu)
        let viewMenu = NSMenu(title: "View")
        viewMenu.autoenablesItems = false

        // Audio Routing
        let audioRoutingItem = NSMenuItem(
            title: "Audio Routing...",
            action: #selector(showAudioRouting(_:)),
            keyEquivalent: ""
        )
        audioRoutingItem.target = self
        audioRoutingItem.isEnabled = true
        viewMenu.addItem(audioRoutingItem)

        viewMenu.addItem(NSMenuItem.separator())

        // Show Onboarding
        let onboardingItem = NSMenuItem(
            title: "Setup Guide...",
            action: #selector(showOnboarding(_:)),
            keyEquivalent: ""
        )
        onboardingItem.target = self
        onboardingItem.isEnabled = true
        viewMenu.addItem(onboardingItem)

        // Insert View menu after Edit (index 3)
        let viewMenuItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        viewMenuItem.submenu = viewMenu

        // Check if View menu already exists
        if let existingViewIndex = mainMenu.items.firstIndex(where: { $0.title == "View" }) {
            mainMenu.removeItem(at: existingViewIndex)
        }
        mainMenu.insertItem(viewMenuItem, at: 3)

        debugPrint("setupMenus: DONE. Added Edit and View menus")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppDelegate.hasUnsavedChanges else {
            return .terminateNow
        }

        // Show alert for unsaved changes
        let alert = NSAlert()
        alert.messageText = "You have unsaved changes"
        alert.informativeText = "Do you want to save your changes before quitting?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn: // Save
            NotificationCenter.default.post(name: .saveProject, object: nil)
            // Give a moment for save to complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.terminate(nil)
            }
            return .terminateCancel

        case .alertSecondButtonReturn: // Don't Save
            return .terminateNow

        case .alertThirdButtonReturn: // Cancel
            return .terminateCancel

        default:
            return .terminateCancel
        }
    }

    // MARK: - Window Delegate

    private func setupWindowDelegate() {
        guard !hasSetupWindowDelegate else { return }

        // Set this as the delegate for all windows and configure appearance
        for window in NSApp.windows {
            if window.delegate == nil || !(window.delegate is AppDelegate) {
                window.delegate = self
                debugPrint("setupWindowDelegate: set delegate for window: %@", window.title)
            }

            // Configure for Liquid Glass appearance
            configureWindowForLiquidGlass(window)
        }

        hasSetupWindowDelegate = true
    }

    /// Configure window for macOS Liquid Glass / vibrancy appearance
    private func configureWindowForLiquidGlass(_ window: NSWindow) {
        // Make the title bar transparent and blend with content
        window.titlebarAppearsTransparent = true

        // Enable full-size content view to extend behind title bar
        window.styleMask.insert(.fullSizeContentView)
        window.styleMask.insert(.resizable)

        // Use a vibrant dark appearance for the window
        window.appearance = NSAppearance(named: .vibrantDark)

        // Make the window background transparent so vibrancy shows through
        window.backgroundColor = .clear

        // Configure the toolbar if present
        if let toolbar = window.toolbar {
            toolbar.displayMode = .iconOnly
        }

        debugPrint("configureWindowForLiquidGlass: configured window for Liquid Glass")
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard AppDelegate.hasUnsavedChanges else {
            return true
        }

        // Show alert for unsaved changes
        let alert = NSAlert()
        alert.messageText = "You have unsaved changes"
        alert.informativeText = "Do you want to save your changes before closing?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn: // Save
            NotificationCenter.default.post(name: .saveProject, object: nil)
            // Give a moment for save to complete, then close
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                sender.close()
            }
            return false

        case .alertSecondButtonReturn: // Don't Save
            return true

        case .alertThirdButtonReturn: // Cancel
            return false

        default:
            return false
        }
    }

    // MARK: - Open File from Finder/Dock

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        debugPrint("AppDelegate.openFile: called with: %@", filename)

        if url.pathExtension.lowercased() == "projector" {
            openProjectFile(url: url)
            return true
        }
        return false
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        debugPrint("AppDelegate.openFiles: called with %d files", filenames.count)
        for filename in filenames {
            _ = application(sender, openFile: filename)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        debugPrint("AppDelegate.open(urls:): called with %d URLs", urls.count)
        for url in urls {
            debugPrint("AppDelegate.open(urls:): processing %@", url.path)
            if url.pathExtension.lowercased() == "projector" {
                openProjectFile(url: url)
            }
        }
    }

    private func openProjectFile(url: URL) {
        debugPrint("AppDelegate.openProjectFile: %@", url.path)

        // Delay notification to ensure SwiftUI view is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            debugPrint("AppDelegate.openProjectFile: posting notification")
            NotificationCenter.default.post(name: .openProjectFile, object: url)
        }
    }

    // MARK: - Menu Validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // Always enable our custom Save menu items
        if menuItem.action == #selector(saveProject(_:)) ||
           menuItem.action == #selector(saveProjectAs(_:)) {
            return true
        }
        return true
    }

    // MARK: - Save Actions (called via selector from menu commands)

    @objc func saveProject(_ sender: Any?) {
        debugPrint("saveProject called, posting notification")
        NSSound.beep() // Audio feedback
        NotificationCenter.default.post(name: .saveProject, object: nil)
    }

    @objc func saveProjectAs(_ sender: Any?) {
        debugPrint("saveProjectAs called, posting notification")
        NotificationCenter.default.post(name: .saveProjectAs, object: nil)
    }

    @objc func openProjectMenu(_ sender: Any?) {
        debugPrint("openProjectMenu called, posting notification")
        NotificationCenter.default.post(name: .openProjectFromMenu, object: nil)
    }

    @objc func consolidateMedia(_ sender: Any?) {
        debugPrint("consolidateMedia called, posting notification")
        NotificationCenter.default.post(name: .consolidateMedia, object: nil)
    }

    // MARK: - Edit Actions

    @objc func editUndo(_ sender: Any?) {
        debugPrint("editUndo called")
        NotificationCenter.default.post(name: .editUndo, object: nil)
    }

    @objc func editRedo(_ sender: Any?) {
        debugPrint("editRedo called")
        NotificationCenter.default.post(name: .editRedo, object: nil)
    }

    @objc func editCut(_ sender: Any?) {
        debugPrint("editCut called")
        NotificationCenter.default.post(name: .editCut, object: nil)
    }

    @objc func editCopy(_ sender: Any?) {
        debugPrint("editCopy called")
        NotificationCenter.default.post(name: .editCopy, object: nil)
    }

    @objc func editPaste(_ sender: Any?) {
        debugPrint("editPaste called")
        NotificationCenter.default.post(name: .editPaste, object: nil)
    }

    @objc func editDelete(_ sender: Any?) {
        debugPrint("editDelete called")
        NotificationCenter.default.post(name: .editDelete, object: nil)
    }

    @objc func editSelectAll(_ sender: Any?) {
        debugPrint("editSelectAll called")
        NotificationCenter.default.post(name: .editSelectAll, object: nil)
    }

    @objc func editDeselectAll(_ sender: Any?) {
        debugPrint("editDeselectAll called")
        NotificationCenter.default.post(name: .editDeselectAll, object: nil)
    }

    // MARK: - View Actions

    @objc func showAudioRouting(_ sender: Any?) {
        debugPrint("showAudioRouting called")
        NotificationCenter.default.post(name: .showAudioRouting, object: nil)
    }

    @objc func showOnboarding(_ sender: Any?) {
        debugPrint("showOnboarding called")
        NotificationCenter.default.post(name: .showOnboarding, object: nil)
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
    static let openProjectFile = Notification.Name("openProjectFile")
    static let openProjectFromMenu = Notification.Name("openProjectFromMenu")
    static let videoFileSelected = Notification.Name("videoFileSelected")
    static let saveProject = Notification.Name("saveProject")
    static let saveProjectAs = Notification.Name("saveProjectAs")
    static let checkUnsavedChanges = Notification.Name("checkUnsavedChanges")
    static let consolidateMedia = Notification.Name("consolidateMedia")

    // Edit menu notifications
    static let editUndo = Notification.Name("editUndo")
    static let editRedo = Notification.Name("editRedo")
    static let editCut = Notification.Name("editCut")
    static let editCopy = Notification.Name("editCopy")
    static let editPaste = Notification.Name("editPaste")
    static let editDelete = Notification.Name("editDelete")
    static let editSelectAll = Notification.Name("editSelectAll")
    static let editDeselectAll = Notification.Name("editDeselectAll")

    // View menu notifications
    static let showAudioRouting = Notification.Name("showAudioRouting")
    static let showOnboarding = Notification.Name("showOnboarding")
}

// MARK: - NSApplication Swizzling for CMD+S

extension NSApplication {
    @objc func projector_sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command),
               let chars = event.charactersIgnoringModifiers?.lowercased() {

                // CMD+S / CMD+Shift+S - Save
                if chars == "s" {
                    if flags.contains(.shift) {
                        debugPrint("Swizzled sendEvent: CMD+Shift+S detected!")
                        NotificationCenter.default.post(name: .saveProjectAs, object: nil)
                    } else {
                        debugPrint("Swizzled sendEvent: CMD+S detected!")
                        NotificationCenter.default.post(name: .saveProject, object: nil)
                    }
                    return
                }

                // CMD+O - Open
                if chars == "o" && !flags.contains(.shift) {
                    debugPrint("Swizzled sendEvent: CMD+O detected!")
                    NotificationCenter.default.post(name: .openProjectFromMenu, object: nil)
                    return
                }
            }
        }
        // Call original (which is now projector_sendEvent due to swizzle)
        projector_sendEvent(event)
    }
}
