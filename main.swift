import Cocoa

// MARK: - Menu Bar Controller

class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let audioRecorder = SystemAudioRecorder()
    let altTabManager = AltTabManager()
    private var recordingMenuItem: NSMenuItem!
    private var durationMenuItem: NSMenuItem!
    private var updateTimer: Timer?
    private var hideAppsMenuItem: NSMenuItem?

    override init() {
        super.init()
        setupMenuBar()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        if let t = updateTimer { RunLoop.main.add(t, forMode: .common) }
    }
    deinit { updateTimer?.invalidate() }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(systemSymbolName: "wrench.and.screwdriver.fill", accessibilityDescription: "Switchboard") {
            image.isTemplate = true
            statusItem.button?.image = image
        } else {
            statusItem.button?.title = "⚙"
        }
        statusItem.button?.toolTip = "Switchboard"

        let menu = NSMenu(); menu.delegate = self

        // Window Switcher
        let hdr1 = NSMenuItem(title: "WINDOW SWITCHER", action: nil, keyEquivalent: "")
        hdr1.attributedTitle = NSAttributedString(string: "WINDOW SWITCHER",
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.secondaryLabelColor])
        menu.addItem(hdr1)

        let altTab = NSMenuItem(title: "  Show Option-Tab (⌥⇥)", action: #selector(showAltTab), keyEquivalent: "")
        altTab.target = self; menu.addItem(altTab)

        hideAppsMenuItem = NSMenuItem(title: "  Hide Apps from Option-Tab", action: nil, keyEquivalent: "")
        menu.addItem(hideAppsMenuItem!)

        menu.addItem(.separator())

        // Audio Recorder
        let hdr2 = NSMenuItem(title: "AUDIO RECORDER", action: nil, keyEquivalent: "")
        hdr2.attributedTitle = NSAttributedString(string: "AUDIO RECORDER",
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.secondaryLabelColor])
        menu.addItem(hdr2)

        recordingMenuItem = NSMenuItem(title: "  ⏺  Record System Audio", action: #selector(toggleRecording), keyEquivalent: "r")
        recordingMenuItem.target = self; menu.addItem(recordingMenuItem)

        durationMenuItem = NSMenuItem(title: "  00:00", action: nil, keyEquivalent: "")
        durationMenuItem.isHidden = true; menu.addItem(durationMenuItem)

        let openFolder = NSMenuItem(title: "  📁 Open Recordings Folder", action: #selector(openRecordings), keyEquivalent: "")
        openFolder.target = self; menu.addItem(openFolder)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "About Switchboard", action: #selector(showAbout), keyEquivalent: "")
        about.target = self; menu.addItem(about)

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)

        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        hideAppsMenuItem?.submenu = buildHideAppsMenu()
    }

    private func buildHideAppsMenu() -> NSMenu {
        let sub = NSMenu()
        let apps = altTabManager.getVisibleApps()
        let excluded = AltTabSettings.shared.excludedAppNames
        for name in apps {
            let item = NSMenuItem(title: "    \(name)", action: #selector(toggleHiddenApp(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = name
            item.state = excluded.contains(name) ? .on : .off
            sub.addItem(item)
        }
        return sub
    }

    @objc private func toggleHiddenApp(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        if AltTabSettings.shared.excludedAppNames.contains(name) {
            AltTabSettings.shared.excludedAppNames.remove(name); sender.state = .off
        } else {
            AltTabSettings.shared.excludedAppNames.insert(name); sender.state = .on
        }
    }

    private func tick() {
        guard AppState.shared.isRecording else { return }
        let d = AppState.shared.recordingDuration
        let str = String(format: "%02d:%02d", Int(d) / 60, Int(d) % 60)
        durationMenuItem.title = "  ⏺  \(str)"
        statusItem.button?.image = nil
        statusItem.button?.title = "⏺ \(str)"
    }

    @objc func showAltTab() { altTabManager.showAltTab() }

    @objc private func toggleRecording() {
        if AppState.shared.isRecording {
            audioRecorder.stopRecording()
            recordingMenuItem.title = "  ⏺  Record System Audio"
            durationMenuItem.isHidden = true; statusItem.button?.title = ""
            let image = NSImage(systemSymbolName: "wrench.and.screwdriver.fill", accessibilityDescription: "Switchboard")
            image?.isTemplate = true
            statusItem.button?.image = image
        } else {
            statusItem.button?.image = nil
            audioRecorder.startRecording { [weak self] in self?.tick() }
            recordingMenuItem.title = "  ⏹  Stop Recording"
            durationMenuItem.isHidden = false
        }
    }

    @objc private func openRecordings() {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Switchboard Recordings")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc private func showAbout() {
        let a = NSAlert()
        a.messageText = "Switchboard v2.0.0"
        a.informativeText = "⌥⇥ Windows-style Option-Tab | ⏺ System Audio Recorder\nBuilt with Swift."
        a.addButton(withTitle: "OK"); a.runModal()
    }

    @objc private func quit() {
        if AppState.shared.isRecording { audioRecorder.stopRecording() }
        NSApp.terminate(nil)
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBarController: MenuBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menuBarController = MenuBarController()
        SwitchboardPermissions.ensureRequiredPermissions { [weak self] in
            self?.menuBarController.altTabManager.registerHotkey()
        }
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
