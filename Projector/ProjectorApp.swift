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

    /// The external events this app answers to: opening a `.projector` document.
    private static let externalEvents: Set<String> = ["projector", "file"]

    /// Documented wildcard for the window-level `allowing:` set - this window
    /// will take any external event rather than let a new one be opened for it.
    private static let anyExternalEvent: Set<String> = ["*"]

    var body: some Scene {
        // Single window app - only one project open at a time.
        //
        // `WindowGroup` rather than `Window`, which is macOS 13+ and would put
        // the floor above the Monterey machines composers are still working on.
        // The group can in principle open more than one window; the New Item
        // command is removed below, which is what actually keeps it to one.
        WindowGroup("Projector", id: "main") {
            ContentView()
                // Without this the group opened a *second* window every time a
                // project was double-clicked in the Finder while the app was
                // already running - a whole second copy of the interface, with
                // its own state, inside the one process. It reads as two
                // instances of the app and the only way out is to close one.
                //
                // The scene modifier below says the group can handle these
                // events; on its own that is a licence to open a new window.
                // This one is the window saying it will take them, which is
                // what makes SwiftUI route the open to the window already on
                // screen. `AppDelegate.application(_:open:)` then loads the
                // project into it, exactly as File > Open does.
                .handlesExternalEvents(
                    preferring: ProjectorApp.externalEvents,
                    allowing: ProjectorApp.anyExternalEvent
                )
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
        .handlesExternalEvents(matching: ProjectorApp.externalEvents)
        .commands {
            // Remove the New Window command from the system menu
            CommandGroup(replacing: .newItem) { }
        }
    }
}


// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSWindowDelegate {
    private var hasSetupMenus = false

    /// Retained so the checkmark can be refreshed when the pin is toggled from
    /// the player window rather than the menu.
    private var pinPlayerMenuItem: NSMenuItem?
    private var hasSetupWindowDelegate = false
    private var activationAttempt = 0
    private let maxActivationAttempts = 6

    /// Checks for and installs new versions.
    ///
    /// Owned by the app delegate rather than a view: it has to outlive every
    /// window, and Sparkle's scheduled check runs whether or not anything is on
    /// screen. Reached only from the application menu's Check for Updates,
    /// which goes through `self` - Settings has no updates section, because a
    /// panel of controls for something that runs itself was three rows
    /// explaining there was nothing to do.
    ///
    /// **If that ever changes, do not reach for this through `NSApp.delegate`.**
    /// `@NSApplicationDelegateAdaptor` installs SwiftUI's own delegate - runtime
    /// class `SwiftUI.AppDelegate` - as the application delegate and forwards
    /// callbacks to this one, so `NSApp.delegate as? AppDelegate` is **always**
    /// nil. Measured, not assumed: `runtime=SwiftUI.AppDelegate
    /// expected=Projector.AppDelegate isKind=false`. That is how the old
    /// Settings section came to be permanently invisible while the menu item
    /// worked perfectly, and the two classes sharing a name is what made it so
    /// hard to see. Publish this property into the environment from the scene
    /// body instead.
    ///
    /// Typed as the protocol, not as ``SparkleUpdateService``, so an App Store
    /// build can supply a different one - see ``UpdateServiceProtocol``.
    ///
    /// The updater is main-actor isolated because Sparkle has to be driven from
    /// the main thread, while this class is not - so every use of it below goes
    /// through `MainActor.assumeIsolated`, as the pin-state observer above
    /// already does. The assumption holds: AppKit creates the delegate on the
    /// main thread, and every caller here is a menu action or a main-queue
    /// callback.
    let updateService: any UpdateServiceProtocol = MainActor.assumeIsolated {
        SparkleUpdateService()
    }

    /// URL to open when the app finishes launching (for file double-click)
    static var pendingOpenURL: URL?

    /// Tracks if there are unsaved changes (set by ContentView)
    static var hasUnsavedChanges = false

    /// Whether to start a fresh copy of the app once this one has quit.
    ///
    /// Set before asking the app to terminate, and acted on only in
    /// `applicationWillTerminate`. Launching the replacement *first* and terminating
    /// afterwards leaves two copies running whenever termination does not go through -
    /// most obviously when the unsaved-changes prompt appears, which the user never
    /// sees because the new window is already in front of it.
    static var shouldRelaunchAfterTermination = false

    /// How long to wait for the replacement instance to start before quitting anyway.
    private static let relaunchHandoffTimeout: TimeInterval = 10

    func applicationDidFinishLaunching(_ notification: Notification) {
        debugPrint("AppDelegate: applicationDidFinishLaunching")

        // Reading it here fixes the session clock at launch rather than at the
        // moment someone first opens a bug report.
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        diagnosticLog(.info, .app, "Launched \(version) at \(SystemFacts.launchDate)")

        // Load Apple's professional video decoders, which macOS does not register on
        // its own. Without this, formats such as Avid DNxHD cannot be decoded even
        // when the Pro Video Formats package is installed. Apple's instruction is that
        // this happens once per process, so it belongs here and nowhere else.
        ProVideoFormats.registerProfessionalDecoders()
        diagnosticLog(
            .info, .app,
            "Professional video decoders registered (package installed: \(ProVideoFormats.packageAppearsInstalled))"
        )

        // Allow developers to exercise onboarding intentionally without making
        // every Debug launch forget the user's completed setup.
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-reset-welcome") {
            AppSettings.shared.hasCompletedWelcome = false
        }
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

        // Keep the "Lock Player to Foreground" checkmark in step when the pin
        // is toggled from the button inside the player window.
        NotificationCenter.default.addObserver(
            forName: .playerWindowPinDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncPinPlayerMenuItemState()
            }
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

        // New Project (clears current and starts fresh)
        let newProjectItem = NSMenuItem(
            title: "New Project",
            action: #selector(newProject(_:)),
            keyEquivalent: "n"
        )
        newProjectItem.target = self
        newProjectItem.isEnabled = true
        newFileMenu.addItem(newProjectItem)

        newFileMenu.addItem(NSMenuItem.separator())

        // Close (single window app, so this just closes the window)
        let closeItem = NSMenuItem(
            title: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        newFileMenu.addItem(closeItem)

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
        //
        // Lowercase "z" with Shift in the modifier mask, never uppercase "Z" with
        // Shift as well: AppKit then wants Shift applied twice and the shortcut
        // matches nothing, which is why Cmd-Shift-Z did nothing at all while the
        // menu item looked correct.
        let redoItem = NSMenuItem(
            title: "Redo",
            action: #selector(editRedo(_:)),
            keyEquivalent: "z"
        )
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        redoItem.target = self
        redoItem.isEnabled = true
        editMenu.addItem(redoItem)

        editMenu.addItem(NSMenuItem.separator())

        // Cut - uses NSResponder chain so TextField gets it when focused
        let cutItem = NSMenuItem(
            title: "Cut",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        )
        editMenu.addItem(cutItem)

        // Copy - uses NSResponder chain
        let copyItem = NSMenuItem(
            title: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        editMenu.addItem(copyItem)

        // Paste - uses NSResponder chain
        let pasteItem = NSMenuItem(
            title: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
        editMenu.addItem(pasteItem)

        // Delete - uses NSResponder chain
        let deleteItem = NSMenuItem(
            title: "Delete",
            action: #selector(NSText.delete(_:)),
            keyEquivalent: "\u{8}" // Backspace
        )
        deleteItem.keyEquivalentModifierMask = []
        editMenu.addItem(deleteItem)

        editMenu.addItem(NSMenuItem.separator())

        // Select All - uses NSResponder chain
        let selectAllItem = NSMenuItem(
            title: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
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

        // Show Video Player window
        let showPlayerItem = NSMenuItem(
            title: "Show Video Player",
            action: #selector(showVideoPlayer(_:)),
            keyEquivalent: "P"
        )
        showPlayerItem.keyEquivalentModifierMask = [.command, .shift]
        showPlayerItem.target = self
        showPlayerItem.isEnabled = true
        viewMenu.addItem(showPlayerItem)

        // Lock Video Player to foreground (checkmark reflects current state)
        let pinPlayerItem = NSMenuItem(
            title: "Lock Player to Foreground",
            action: #selector(togglePlayerPinned(_:)),
            keyEquivalent: ""
        )
        pinPlayerItem.target = self
        pinPlayerItem.isEnabled = true
        pinPlayerItem.state = AppSettings.shared.playerWindowPinnedToFront ? .on : .off
        viewMenu.addItem(pinPlayerItem)
        self.pinPlayerMenuItem = pinPlayerItem

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

        // Help > Report a Bug.
        //
        // The menus above are inserted at fixed indices because this code owns
        // them outright. Help is different: macOS keeps it last and may have
        // built one already, so this appends to whatever is there instead of
        // replacing a menu the system is entitled to add its own items to.
        let helpMenu: NSMenu
        if let existing = mainMenu.items.first(where: { $0.title == "Help" })?.submenu {
            helpMenu = existing
        } else {
            helpMenu = NSMenu(title: "Help")
            let helpMenuItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
            helpMenuItem.submenu = helpMenu
            mainMenu.addItem(helpMenuItem)
        }

        // Guarded on the title so a second pass cannot stack duplicates in a
        // menu this code does not exclusively own.
        if !helpMenu.items.contains(where: { $0.title == Self.reportBugMenuTitle }) {
            let reportBugItem = NSMenuItem(
                title: Self.reportBugMenuTitle,
                action: #selector(reportBug(_:)),
                keyEquivalent: ""
            )
            reportBugItem.target = self
            reportBugItem.isEnabled = true
            helpMenu.addItem(reportBugItem)
        }

        // Projector > Check for Updates.
        //
        // Same treatment as Help, and for the same reason: the application menu
        // is built by macOS from the bundle name and already holds About,
        // Services, Hide and Quit. This slots one item in below About - where
        // every Mac app puts it - rather than rebuilding a menu the system owns.
        // Omitted entirely when this build cannot update itself, rather than
        // offered and permanently greyed out - a disabled item invites the
        // question of what would enable it.
        if MainActor.assumeIsolated({ updateService.isEnabled }),
           let appMenu = mainMenu.items.first?.submenu,
           !appMenu.items.contains(where: { $0.title == Self.checkForUpdatesMenuTitle }) {
            let updatesItem = NSMenuItem(
                title: Self.checkForUpdatesMenuTitle,
                action: #selector(checkForUpdates(_:)),
                keyEquivalent: ""
            )
            updatesItem.target = self

            // Below About when there is one, otherwise at the top. Falling back
            // to the top rather than skipping the item keeps the menu useful on
            // a system that ever stops adding About for us.
            let aboutIndex = appMenu.items.firstIndex { $0.title.hasPrefix("About") }
            let insertionIndex = aboutIndex.map { $0 + 1 } ?? 0
            appMenu.insertItem(updatesItem, at: insertionIndex)
            appMenu.insertItem(NSMenuItem.separator(), at: insertionIndex + 1)
        }

        // Projector > About Projector.
        //
        // Retargeted, not replaced. macOS builds this item and its panel from the
        // bundle, and the standard panel already reads the name, version and
        // copyright out of Info.plist - so the only thing missing is the credit
        // line, which `orderFrontStandardAboutPanel(options:)` takes directly.
        // Pointing the existing item at our own action is the whole change; a
        // hand-built About window would have to re-earn all of that.
        if let appMenu = mainMenu.items.first?.submenu,
           let aboutItem = appMenu.items.first(where: { $0.title.hasPrefix("About") }) {
            aboutItem.action = #selector(showAboutPanel(_:))
            aboutItem.target = self
        }

        debugPrint("setupMenus: DONE. Added Edit, View and Help menus")
    }

    /// The credit line in the About panel.
    private static let aboutCredit = "Built in LA by So Pitted LLC"

    /// The site the About panel links to, shown without its scheme.
    private static let aboutSiteDisplay = "sopitted.llc"
    private static let aboutSiteURL = URL(string: "https://sopitted.llc")!

    /// Shows the standard About panel with our credit and a link to the site.
    ///
    /// The credit is an `NSAttributedString` rather than plain text because the
    /// URL has to be clickable: a `.link` attribute makes the panel's text view
    /// open it in the browser on its own, with no action of ours to wire up.
    @objc private func showAboutPanel(_ sender: Any?) {
        MainActor.assumeIsolated {
            let centred = NSMutableParagraphStyle()
            centred.alignment = .center

            let credits = NSMutableAttributedString(
                string: Self.aboutCredit + "\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
            credits.append(NSAttributedString(
                string: Self.aboutSiteDisplay,
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .link: Self.aboutSiteURL
                ]
            ))
            credits.addAttribute(
                .paragraphStyle,
                value: centred,
                range: NSRange(location: 0, length: credits.length)
            )

            NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Title of the Help menu item, also used to avoid adding it twice.
    private static let reportBugMenuTitle = "Report a Bug..."

    /// Title of the application menu's update item, also used to avoid adding it twice.
    private static let checkForUpdatesMenuTitle = "Check for Updates..."

    /// Checks because the user asked, and reports the answer either way.
    @objc private func checkForUpdates(_ sender: Any?) {
        MainActor.assumeIsolated { updateService.checkForUpdates() }
    }

    /// Asks the main view to open the bug report sheet.
    @objc private func reportBug(_ sender: Any?) {
        NotificationCenter.default.post(name: .projectorReportBugRequested, object: nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    /// Starts a replacement instance, when a relaunch was asked for.
    ///
    /// Runs only once termination is actually going ahead, so a user who cancels at
    /// the unsaved-changes prompt keeps the single running app they already had.
    ///
    /// Blocking the main thread here is deliberate and safe: the process is on its way
    /// out, and the launch has to be handed to the system before it goes. The
    /// completion arrives on another queue, so the wait cannot deadlock.
    func applicationWillTerminate(_ notification: Notification) {
        // Hand CoreAudio back first. Nothing here can reach the playback engine,
        // so the owning view does it - synchronously, because the process is about
        // to go and a queued cleanup would never run.
        //
        // Without this the engine, its tap and its property listener were released
        // only by process exit, and not at all when a build was killed rather than
        // quit - which is how a day of testing leaves state behind in coreaudiod.
        NotificationCenter.default.post(name: .projectorWillTerminate, object: nil)

        guard AppDelegate.shouldRelaunchAfterTermination else { return }
        AppDelegate.shouldRelaunchAfterTermination = false

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true

        let handoff = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { _, error in
            if let error {
                diagnosticLog(.error, .app, "Relaunch failed: \(error.localizedDescription)")
            }
            handoff.signal()
        }
        _ = handoff.wait(timeout: .now() + AppDelegate.relaunchHandoffTimeout)
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

        // Adopt only windows that have NO delegate of their own.
        //
        // The old condition (`delegate == nil || !(delegate is AppDelegate)`)
        // stole the delegate from any window that already had one - including
        // the player window, whose PlayerWindowController implements
        // hide-on-close. Once hijacked, closing the player ran AppDelegate's
        // windowShouldClose and prompted to save the whole project.
        for window in NSApp.windows {
            if window.delegate == nil {
                window.delegate = self
                debugPrint("setupWindowDelegate: set delegate for window: %@", window.title)
            } else if !(window.delegate is AppDelegate) {
                debugPrint("setupWindowDelegate: leaving window '%@' to its own delegate", window.title)
            }

            // Configure for Liquid Glass appearance
            configureWindowForLiquidGlass(window)
        }

        hasSetupWindowDelegate = true
    }

    /// Configure window for macOS Liquid Glass / vibrancy appearance
    private func configureWindowForLiquidGlass(_ window: NSWindow) {
        // The player window styles itself (hidden traffic lights, black
        // background for video) - a transparent background and vibrancy would
        // undo both.
        guard !(window.delegate is PlayerWindowController) else { return }

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
        // Greyed out while a check or install is already running, so the item
        // cannot start a second one on top of the first.
        if menuItem.action == #selector(checkForUpdates(_:)) {
            return MainActor.assumeIsolated { updateService.canCheckForUpdates }
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

    @objc func newProject(_ sender: Any?) {
        debugPrint("newProject called, posting notification")
        NotificationCenter.default.post(name: .newProject, object: nil)
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

    @objc func showOnboarding(_ sender: Any?) {
        debugPrint("showOnboarding called")
        NotificationCenter.default.post(name: .showOnboarding, object: nil)
    }

    // MARK: - Player Window Actions

    @MainActor
    @objc func showVideoPlayer(_ sender: Any?) {
        debugPrint("showVideoPlayer called")
        PlayerWindowController.shared.show()
    }

    @MainActor
    @objc func togglePlayerPinned(_ sender: Any?) {
        PlayerWindowController.shared.togglePinnedToFront()
        debugPrint("togglePlayerPinned -> \(AppSettings.shared.playerWindowPinnedToFront)")
        syncPinPlayerMenuItemState()
    }

    /// Keep the menu checkmark in step with the pin state, whichever surface
    /// changed it (menu item or the button in the player window).
    @MainActor
    private func syncPinPlayerMenuItemState() {
        pinPlayerMenuItem?.state = AppSettings.shared.playerWindowPinnedToFront ? .on : .off
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
    static let newProject = Notification.Name("newProject")
    static let videoFileSelected = Notification.Name("videoFileSelected")
    static let saveProject = Notification.Name("saveProject")

    /// Posted by Help > Report a Bug. The menu is AppKit and has no path to
    /// `ContentView`'s state, so it asks for the sheet this way.
    static let projectorReportBugRequested = Notification.Name("projectorReportBugRequested")

    /// Asks the interface to close anything modal, because the app is about to be
    /// asked to quit and AppKit refuses to terminate behind a sheet. Posted by the
    /// updater; see `SparkleUpdateService`.
    static let projectorDismissModalsRequested = Notification.Name("projectorDismissModalsRequested")

    /// The app is quitting: release CoreAudio before the process goes.
    ///
    /// Posted from `applicationWillTerminate`, which cannot reach the engine - it
    /// belongs to the view tree - so the view that owns it does the releasing.
    static let projectorWillTerminate = Notification.Name("projectorWillTerminate")
    static let saveProjectAs = Notification.Name("saveProjectAs")
    static let checkUnsavedChanges = Notification.Name("checkUnsavedChanges")

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

                // CMD+N - New Project (intercept to prevent new window)
                if chars == "n" && !flags.contains(.shift) {
                    debugPrint("Swizzled sendEvent: CMD+N detected!")
                    NotificationCenter.default.post(name: .newProject, object: nil)
                    return
                }
            }
        }
        // Call original (which is now projector_sendEvent due to swizzle)
        projector_sendEvent(event)
    }
}
