import Cocoa

// MARK: - Menu Bar Controller

class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let audioRecorder = SystemAudioRecorder()
    private let audioDownloader = AudioDownloader.shared
    private let dictationManager = DictationManager()
    let altTabManager = AltTabManager()
    private var recordingMenuItem: NSMenuItem!
    private var durationMenuItem: NSMenuItem!
    private var downloadClipboardMenuItem: NSMenuItem!
    private var downloadURLMenuItem: NSMenuItem!
    private var downloadProgressMenuItem: NSMenuItem!
    private var cancelDownloadMenuItem: NSMenuItem!
    private var updateTimer: Timer?
    private var hideAppsMenuItem: NSMenuItem?
    private var dictationStatusMenuItem: NSMenuItem?

    override init() {
        super.init()
        setupMenuBar()
        wireDictationHotkeys()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        if let t = updateTimer { RunLoop.main.add(t, forMode: .common) }
    }

    private func wireDictationHotkeys() {
        altTabManager.onOptionSpaceDown = { [weak self] in self?.dictationManager.spaceDown() }
        altTabManager.onOptionSpaceUp = { [weak self] in self?.dictationManager.spaceUp() }
        altTabManager.onOptionReleasedDuringDictation = { [weak self] in self?.dictationManager.optionReleased() }
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

        // Dictation
        let hdrDictation = NSMenuItem(title: "DICTATION", action: nil, keyEquivalent: "")
        hdrDictation.attributedTitle = NSAttributedString(string: "DICTATION",
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.secondaryLabelColor])
        menu.addItem(hdrDictation)

        let dictation = NSMenuItem(title: "  Hold ⌥Space to Dictate", action: nil, keyEquivalent: "")
        dictation.toolTip = "Offline speech-to-text via whisper-small"
        menu.addItem(dictation)

        dictationStatusMenuItem = NSMenuItem(title: "  Checking setup…", action: nil, keyEquivalent: "")
        dictationStatusMenuItem?.isEnabled = false
        menu.addItem(dictationStatusMenuItem!)

        menu.addItem(.separator())

        // Audio
        let hdr2 = NSMenuItem(title: "AUDIO", action: nil, keyEquivalent: "")
        hdr2.attributedTitle = NSAttributedString(string: "AUDIO",
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.secondaryLabelColor])
        menu.addItem(hdr2)

        recordingMenuItem = NSMenuItem(title: "  ⏺  Record System Audio", action: #selector(toggleRecording), keyEquivalent: "r")
        recordingMenuItem.target = self; menu.addItem(recordingMenuItem)

        durationMenuItem = NSMenuItem(title: "  00:00", action: nil, keyEquivalent: "")
        durationMenuItem.isHidden = true; menu.addItem(durationMenuItem)

        downloadClipboardMenuItem = NSMenuItem(title: "  ⬇︎  Download from Clipboard", action: #selector(downloadFromClipboard), keyEquivalent: "d")
        downloadClipboardMenuItem.target = self; menu.addItem(downloadClipboardMenuItem)

        downloadURLMenuItem = NSMenuItem(title: "  ⬇︎  Enter URL…", action: #selector(downloadFromURL), keyEquivalent: "D")
        downloadURLMenuItem.target = self; menu.addItem(downloadURLMenuItem)

        downloadProgressMenuItem = NSMenuItem(title: "  ⬇︎  Downloading…", action: nil, keyEquivalent: "")
        downloadProgressMenuItem.isHidden = true; menu.addItem(downloadProgressMenuItem)

        cancelDownloadMenuItem = NSMenuItem(title: "  ✕  Cancel Download", action: #selector(cancelDownload), keyEquivalent: "")
        cancelDownloadMenuItem.target = self
        cancelDownloadMenuItem.isHidden = true
        menu.addItem(cancelDownloadMenuItem)

        let openFolder = NSMenuItem(title: "  📁 Open Switchboard Folder", action: #selector(openRecordings), keyEquivalent: "")
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
        updateDownloadMenuState()
        updateDictationMenuState()
    }

    private func updateDictationMenuState() {
        let status = dictationManager.setupStatus
        dictationStatusMenuItem?.title = "  \(status.detail)"
        dictationStatusMenuItem?.toolTip = status.tooltip
    }

    private func updateDownloadMenuState() {
        guard !audioDownloader.isDownloading else { return }

        if let url = clipboardURLString() {
            downloadClipboardMenuItem.isEnabled = true
            downloadClipboardMenuItem.toolTip = url
            if let host = URL(string: url)?.host {
                let preview = host.count > 28 ? String(host.prefix(25)) + "…" : host
                downloadClipboardMenuItem.title = "  ⬇︎  Download from Clipboard  ·  \(preview)"
            } else {
                downloadClipboardMenuItem.title = "  ⬇︎  Download from Clipboard"
            }
        } else {
            downloadClipboardMenuItem.isEnabled = false
            downloadClipboardMenuItem.title = "  ⬇︎  Download from Clipboard"
            downloadClipboardMenuItem.toolTip = "Copy a link first, or use Enter URL…"
        }
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
            recordingMenuItem.isEnabled = true
            durationMenuItem.isHidden = true
            statusItem.button?.title = ""
            let image = NSImage(systemSymbolName: "wrench.and.screwdriver.fill", accessibilityDescription: "Switchboard")
            image?.isTemplate = true
            statusItem.button?.image = image
        } else {
            SwitchboardPermissions.requestScreenRecordingForThumbnails()
            // Show feedback immediately while ScreenCaptureKit spins up (can take ~300ms).
            recordingMenuItem.title = "  ⏺  Starting…"
            recordingMenuItem.isEnabled = false
            statusItem.button?.image = nil
            statusItem.button?.title = "⏺"

            audioRecorder.startRecording(
                onStart: { [weak self] in
                    guard let self else { return }
                    self.recordingMenuItem.title = "  ⏹  Stop Recording"
                    self.recordingMenuItem.isEnabled = true
                    self.durationMenuItem.isHidden = false
                    self.tick()
                },
                onError: { [weak self] in
                    guard let self else { return }
                    // Restore idle state — screen recording permission may be missing.
                    self.recordingMenuItem.title = "  ⏺  Record System Audio"
                    self.recordingMenuItem.isEnabled = true
                    self.statusItem.button?.title = ""
                    let image = NSImage(systemSymbolName: "wrench.and.screwdriver.fill", accessibilityDescription: "Switchboard")
                    image?.isTemplate = true
                    self.statusItem.button?.image = image
                }
            )
        }
    }

    @objc private func openRecordings() {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Switchboard")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc private func downloadFromClipboard() {
        if let url = clipboardURLString() {
            beginDownload(urlString: url)
        } else {
            downloadFromURL()
        }
    }

    @objc private func downloadFromURL() {
        let alert = NSAlert()
        alert.messageText = "Download Audio"
        alert.informativeText = "Paste a URL to a YouTube video, SoundCloud track, direct audio file, or other supported media page.\n\nSupported: YouTube, Vimeo, SoundCloud, Bandcamp, direct .mp3/.m4a, and more.\n\nRequires: brew install yt-dlp ffmpeg"
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")

        let input = PasteableTextField(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
        input.placeholderString = "https://..."
        input.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        if let clip = clipboardURLString() { input.stringValue = clip }
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let urlString = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty else { return }
        beginDownload(urlString: urlString)
    }

    private func clipboardURLString() -> String? {
        guard let raw = NSPasteboard.general.string(forType: .string) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else { return nil }
        return trimmed
    }

    private func beginDownload(urlString: String) {
        downloadClipboardMenuItem.isEnabled = false
        downloadURLMenuItem.isEnabled = false
        downloadProgressMenuItem.isHidden = false
        cancelDownloadMenuItem.isHidden = false
        statusItem.button?.image = nil
        statusItem.button?.title = "⬇︎"

        audioDownloader.onProgress = { [weak self] progress in
            guard let self else { return }
            if let pct = progress {
                let label = String(format: "%.0f%%", pct * 100)
                self.downloadProgressMenuItem.title = "  ⬇︎  Downloading… \(label)"
                self.statusItem.button?.title = "⬇︎ \(label)"
            } else {
                self.downloadProgressMenuItem.title = "  ⬇︎  Downloading…"
                self.statusItem.button?.title = "⬇︎"
            }
        }

        audioDownloader.startDownload(urlString: urlString) { [weak self] result in
            self?.finishDownload(result: result)
        }
    }

    @objc private func cancelDownload() {
        audioDownloader.cancelDownload()
        resetDownloadMenu()
    }

    private func finishDownload(result: DownloadResult) {
        resetDownloadMenu()

        switch result {
        case .success(let url):
            let alert = NSAlert()
            alert.messageText = "Download Complete"
            alert.informativeText = "Saved to:\n\(url.path)"
            alert.addButton(withTitle: "Show in Finder")
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }

        case .failure(let message):
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Download Failed"
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.runModal()

        case .cancelled:
            break
        }
    }

    private func resetDownloadMenu() {
        audioDownloader.onProgress = nil
        downloadProgressMenuItem.isHidden = true
        downloadProgressMenuItem.title = "  ⬇︎  Downloading…"
        downloadURLMenuItem.isEnabled = true
        cancelDownloadMenuItem.isHidden = true
        updateDownloadMenuState()
        if !AppState.shared.isRecording {
            let image = NSImage(systemSymbolName: "wrench.and.screwdriver.fill", accessibilityDescription: "Switchboard")
            image?.isTemplate = true
            statusItem.button?.image = image
            statusItem.button?.title = ""
        }
    }

    @objc private func showAbout() {
        let a = NSAlert()
        a.messageText = "Switchboard v2.2.0"
        a.informativeText = "⌥⇥  Windows-style Option-Tab switcher\n⌥Space  Hold to dictate (whisper-small)\n⏺  System audio recorder\n⬇︎  Audio URL downloader\n\nBuilt with Swift."
        a.addButton(withTitle: "OK"); a.runModal()
    }

    @objc private func quit() {
        if AppState.shared.isRecording { audioRecorder.stopRecording() }
        if audioDownloader.isDownloading { audioDownloader.cancelDownload() }
        dictationManager.cancelIfNeeded()
        NSApp.terminate(nil)
    }
}

// MARK: - Pasteable Text Field

/// NSTextField subclass that correctly routes ⌘V/C/A/X/Z through the
/// field editor when used inside an NSAlert accessory view.
class PasteableTextField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "v": return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
        case "c": return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
        case "a": return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
        case "x": return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
        case "z": return NSApp.sendAction(Selector(("undo:")), to: nil, from: self)
        default:  return super.performKeyEquivalent(with: event)
        }
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
