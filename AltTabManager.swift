import ApplicationServices
import Carbon
import Cocoa
import CoreGraphics
import ScreenCaptureKit

// MARK: - App State
class AppState: ObservableObject {
    static let shared = AppState()
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var lastRecordingURL: URL?
}

// MARK: - Window Info
struct WindowInfo {
    let windowID: CGWindowID
    let title: String, appName: String
    let bounds: CGRect
    let pid: pid_t, alpha: Double, windowLayer: Int
}

private struct AltTabLayout {
    let columns: Int
    let rows: Int
    let thumbnailSize: CGSize
    let panelSize: CGSize
    let contentSize: CGSize
    let needsScroll: Bool
    let padding: CGFloat
    let gap: CGFloat
    let labelHeight: CGFloat
    let labelGap: CGFloat
}

// MARK: - Thumbnail Cache
class ThumbnailCache {
    static let shared = ThumbnailCache()
    private var cache: [CGWindowID: NSImage] = [:]
    private let maxEntries = 128
    func get(_ id: CGWindowID) -> NSImage? { cache[id] }
    func set(_ id: CGWindowID, image: NSImage) {
        if cache.count >= maxEntries { cache.keys.prefix(maxEntries/2).forEach { cache.removeValue(forKey: $0) } }
        cache[id] = image
    }
}

// MARK: - Settings
class AltTabSettings {
    static let shared = AltTabSettings()
    var excludedAppNames: Set<String> = [
        "Stickies", "Window Server", "SystemUIServer",
        "ControlCenter", "Spotlight", "loginwindow",
        "Notification Centre", "NotificationCenter", "Notification Center",
        "Widgets", "WidgetBoard", "widgetsimulator",
    ]
}

// MARK: - Permissions
class SwitchboardPermissions {
    private static var setupTimer: Timer?
    private static var alertIsShowing = false
    private static var onReadyCallbacks: [() -> Void] = []
    private static var screenRecordingProbeStream: SCStream?
    private static var screenRecordingProbeHandler: ScreenRecordingProbeHandler?

    static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    static var hasScreenRecording: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func requestMissingPermissions() -> Bool {
        if !hasAccessibility {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
        return hasAccessibility
    }

    static func ensureRequiredPermissions(onReady: @escaping () -> Void) {
        if hasAccessibility {
            onReady()
            return
        }

        onReadyCallbacks.append(onReady)
        requestMissingPermissions()
        showPermissionSetupAlert()
        startPermissionPolling()
    }

    static func showSetupAlertIfNeeded() {
        guard !hasAccessibility else { return }
        requestMissingPermissions()
        showPermissionSetupAlert()
        startPermissionPolling()
    }

    static func showSwitcherBlockedAlertIfNeeded() {
        guard !hasAccessibility else { return }
        showPermissionSetupAlert()
        startPermissionPolling()
    }

    private static func startPermissionPolling() {
        guard setupTimer == nil else { return }
        setupTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            if hasAccessibility {
                finishPermissionSetup()
            }
        }
        if let setupTimer { RunLoop.main.add(setupTimer, forMode: .common) }
    }

    private static func finishPermissionSetup() {
        setupTimer?.invalidate()
        setupTimer = nil
        let callbacks = onReadyCallbacks
        onReadyCallbacks.removeAll()
        callbacks.forEach { $0() }
    }

    private static func showPermissionSetupAlert() {
        guard !alertIsShowing, !hasAccessibility else { return }
        alertIsShowing = true

        let alert = NSAlert()
        alert.messageText = "Switchboard Needs Permissions"
        alert.informativeText = permissionMessage()
        if !hasAccessibility { alert.addButton(withTitle: "Open Accessibility") }
        alert.addButton(withTitle: "Check Again")
        alert.addButton(withTitle: "Quit")
        NSApp.activate()
        let response = alert.runModal()
        alertIsShowing = false

        let openedSettings = handlePermissionAlertResponse(response)

        if hasAccessibility {
            finishPermissionSetup()
        } else {
            let delay: TimeInterval = openedSettings ? 8 : 0.75
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                showPermissionSetupAlert()
            }
        }
    }

    @discardableResult
    private static func handlePermissionAlertResponse(_ response: NSApplication.ModalResponse) -> Bool {
        var buttonIndex = 1
        if !hasAccessibility {
            if response.rawValue == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + buttonIndex - 1 {
                openPrivacyPane("Privacy_Accessibility")
                return true
            }
            buttonIndex += 1
        }
        if response.rawValue == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + buttonIndex {
            NSApp.terminate(nil)
        }
        return false
    }

    private static func permissionMessage() -> String {
        return """
        Option-Tab needs Accessibility to listen for the keyboard shortcut and switch windows.

        Screen Recording is only needed for thumbnails. If it is not granted yet, Switchboard will still open with app icons and will request thumbnail permission when previews are captured.
        """
    }

    static func requestScreenRecordingForThumbnails() {
        guard !hasScreenRecording else { return }
        CGRequestScreenCaptureAccess()
        triggerScreenRecordingRegistration()
    }

    private static func triggerScreenRecordingRegistration() {
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else { return }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = max(1, Int(display.width))
                config.height = max(1, Int(display.height))
                config.showsCursor = false
                config.minimumFrameInterval = CMTime(value: 1, timescale: 2)
                config.queueDepth = 1

                let handler = ScreenRecordingProbeHandler()
                let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                screenRecordingProbeHandler = handler
                screenRecordingProbeStream = stream
                try stream.addStreamOutput(handler, type: .screen, sampleHandlerQueue: .main)
                try await stream.startCapture()
                try await Task.sleep(nanoseconds: 800_000_000)
                try await stream.stopCapture()
                try stream.removeStreamOutput(handler, type: .screen)
                screenRecordingProbeStream = nil
                screenRecordingProbeHandler = nil
            } catch {
                // A denied capture is still useful: it forces macOS TCC to register the app.
                print("Switchboard: Screen Recording registration attempt: \(error.localizedDescription)")
                screenRecordingProbeStream = nil
                screenRecordingProbeHandler = nil
            }
        }
    }

    private static func openPrivacyPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - AltTab Manager
class AltTabManager: NSObject {
    private var altTabPanel: NSPanel?
    private var selectedIndex = 0
    private var windows: [WindowInfo] = []
    private var thumbnailViews: [ThumbnailImageView] = []
    private var thumbnailViewsByWindowID: [CGWindowID: ThumbnailImageView] = [:]
    private var labelViews: [NSTextField] = []
    private var iconViews: [NSImageView] = []
    private var tileViews: [ThumbnailTileView] = []
    private var isShowing = false
    private var isProcessingHotkey = false
    private var optionKeyHeld = false
    private var lastOptionTabAt: TimeInterval = 0
    private var initialMouseLocation: CGPoint?
    private var mouseSelectionEnabled = false
    private var captureTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var globalKeyMonitor: Any?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        captureTask?.cancel(); refreshTask?.cancel()
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let eventTapSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), eventTapSource, .commonModes) }
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        NotificationCenter.default.removeObserver(self)
    }

    func registerHotkey() {
        guard eventTap == nil else { return }
        let mask = CGEventMask(
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.mouseMoved.rawValue)
        )
        guard let tap = makeEventTap(at: .cghidEventTap, mask: mask) ?? makeEventTap(at: .cgSessionEventTap, mask: mask) else {
            print("Switchboard: CGEvent tap failed — grant Accessibility")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap; eventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handleGlobalNSEvent(event)
        }
        registerCarbonHotkey()
        print("Switchboard: hotkey ready")
    }

    private func registerCarbonHotkey() {
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let manager = Unmanaged<AltTabManager>.fromOpaque(userData).takeUnretainedValue()
                manager.triggerOptionTab()
                return noErr
            },
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &hotKeyHandler
        )

        let hotKeyID = EventHotKeyID(signature: Self.fourCharCode("SWBD"), id: 1)
        RegisterEventHotKey(UInt32(kVK_Tab), UInt32(optionKey), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    private static func fourCharCode(_ value: String) -> OSType {
        value.utf8.reduce(0) { ($0 << 8) + OSType($1) }
    }

    private func makeEventTap(at location: CGEventTapLocation, mask: CGEventMask) -> CFMachPort? {
        CGEvent.tapCreate(
            tap: location, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, ctx in
                let manager = Unmanaged<AltTabManager>.fromOpaque(ctx!).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = manager.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passRetained(event)
                }
                return manager.handleCGEvent(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
    }

    private func handleGlobalNSEvent(_ event: NSEvent) {
        if event.type == .flagsChanged {
            optionKeyHeld = event.modifierFlags.contains(.option)
            return
        }
        guard event.type == .keyDown,
              event.keyCode == 48,
              event.modifierFlags.contains(.option) else { return }
        triggerOptionTab()
    }

    private func triggerOptionTab() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastOptionTabAt > 0.08 else { return }
        lastOptionTabAt = now
        optionKeyHeld = true
        initialMouseLocation = NSEvent.mouseLocation
        mouseSelectionEnabled = false
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isProcessingHotkey else { return }
            self.isProcessingHotkey = true
            if self.isShowing {
                self.selectedIndex = (self.selectedIndex + 1) % max(self.windows.count, 1)
                self.updateSelection()
            } else {
                self.showAltTab()
            }
            self.isProcessingHotkey = false
        }
    }

    private func handleCGEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .mouseMoved, isShowing {
            handleSwitcherMouseMoved(at: event.location)
            return Unmanaged.passRetained(event)
        }
        if type == .leftMouseDown, isShowing {
            if handleSwitcherMouseDown(at: event.location) {
                return nil
            }
        }
        if type == .flagsChanged {
            let optionNow = event.flags.contains(.maskAlternate)
            if !optionNow && optionKeyHeld && isShowing {
                optionKeyHeld = false
                DispatchQueue.main.async { [weak self] in self?.activateSelectedAndHide() }
                return nil
            }
            optionKeyHeld = optionNow
            return Unmanaged.passRetained(event)
        }
        if type == .keyDown {
            let kc = event.getIntegerValueField(.keyboardEventKeycode)
            if event.flags.contains(.maskAlternate) && kc == 48 {
                triggerOptionTab()
                return nil
            }
            if kc == 53, isShowing { DispatchQueue.main.async { [weak self] in self?.hideAltTab() }; return nil }
            if (kc == 36 || kc == 76), isShowing { DispatchQueue.main.async { [weak self] in self?.activateSelectedAndHide() }; return nil }
        }
        return Unmanaged.passRetained(event)
    }

    // MARK: - Show Panel (adaptive grid layout)

    func showAltTab() {
        guard SwitchboardPermissions.hasAccessibility else {
            SwitchboardPermissions.showSwitcherBlockedAlertIfNeeded()
            return
        }
        SwitchboardPermissions.requestScreenRecordingForThumbnails()
        refreshTask?.cancel()
        windows = getWindows()
        guard !windows.isEmpty else { return }
        initialMouseLocation = NSEvent.mouseLocation
        mouseSelectionEnabled = false
        selectedIndex = 0; isShowing = true
        renderPanel(restartCapture: true)
    }

    private func renderPanel(restartCapture: Bool) {
        guard isShowing, !windows.isEmpty else { return }

        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let screen = preferredScreen()?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let layout = computeLayout(for: windows, in: screen)

        let x = screen.origin.x + (screen.width - layout.panelSize.width) / 2
        let y = screen.origin.y + (screen.height - layout.panelSize.height) / 2
        let frame = NSRect(origin: CGPoint(x: x, y: y), size: layout.panelSize)

        let panel = altTabPanel ?? NSPanel(contentRect: frame,
            styleMask: [.nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        if altTabPanel == nil {
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.titlebarAppearsTransparent = true; panel.titleVisibility = .hidden
            panel.isMovableByWindowBackground = false; panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = false
            panel.acceptsMouseMovedEvents = true
        } else {
            panel.setFrame(frame, display: false)
        }
        panel.backgroundColor = isDark ? NSColor(white: 0.12, alpha: 0.96) : NSColor(white: 0.95, alpha: 0.96)

        let gridView = NSView(frame: NSRect(origin: .zero, size: layout.contentSize))
        gridView.wantsLayer = true; gridView.layer?.cornerRadius = 16; gridView.layer?.masksToBounds = true
        buildGrid(in: gridView, layout: layout, isDark: isDark)

        if layout.needsScroll {
            let scroll = NSScrollView(frame: NSRect(origin: .zero, size: layout.panelSize))
            scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
            scroll.autohidesScrollers = true
            scroll.borderType = .noBorder
            scroll.drawsBackground = false
            scroll.documentView = gridView
            panel.contentView = scroll
            let topOrigin = max(0, layout.contentSize.height - layout.panelSize.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: topOrigin))
            scroll.reflectScrolledClipView(scroll.contentView)
        } else {
            panel.contentView = gridView
        }

        panel.orderFrontRegardless(); panel.makeKey(); altTabPanel = panel

        if restartCapture {
            captureThumbnails(thumbW: layout.thumbnailSize.width, thumbH: layout.thumbnailSize.height)
            startBackgroundRefresh(thumbW: layout.thumbnailSize.width, thumbH: layout.thumbnailSize.height)
        }
    }

    private func computeLayout(for windows: [WindowInfo], in screen: CGRect) -> AltTabLayout {
        let count = max(windows.count, 1)
        let padding = max(18, min(32, screen.width * 0.025))
        let gap = max(12, min(20, screen.width * 0.014))
        let labelHeight = max(18, min(24, screen.height * 0.024))
        let labelGap: CGFloat = 8
        let outerMargin = max(52, min(110, screen.width * 0.06))
        let maxPanelW = max(320, min(screen.width - outerMargin * 2, screen.width * 0.86))
        let maxPanelH = max(240, screen.height * 0.72)
        let availableW = max(1, maxPanelW - padding * 2)
        let availableH = max(1, maxPanelH - padding * 2)
        let aspect = representativeAspectRatio(for: windows)
        let minThumbW = max(150, min(220, screen.width * 0.14))
        let maxThumbW = max(320, min(460, screen.width * 0.34))

        var bestCols = 1
        var bestRows = count
        var bestThumbW: CGFloat = 0
        var bestScore: CGFloat = -1

        for cols in 1...count {
            let rows = Int(ceil(Double(count) / Double(cols)))
            let rowChrome = CGFloat(rows) * (labelHeight + labelGap)
            let wByCols = (availableW - gap * CGFloat(cols - 1)) / CGFloat(cols)
            let hByRows = (availableH - gap * CGFloat(rows - 1) - rowChrome) / CGFloat(rows)
            let thumbW = min(maxThumbW, wByCols, hByRows * aspect)
            guard thumbW >= minThumbW else { continue }
            let score = thumbW * (thumbW / aspect)
            if score > bestScore {
                bestScore = score; bestThumbW = thumbW; bestCols = cols; bestRows = rows
            }
        }

        if bestThumbW < minThumbW {
            bestCols = max(1, Int((availableW + gap) / (minThumbW + gap)))
            bestRows = Int(ceil(Double(count) / Double(bestCols)))
            let wByCols = (availableW - gap * CGFloat(bestCols - 1)) / CGFloat(bestCols)
            bestThumbW = max(minThumbW, min(maxThumbW, wByCols))
        }

        let thumbH = bestThumbW / aspect
        let cellH = thumbH + labelGap + labelHeight
        let contentW = CGFloat(bestCols) * bestThumbW + CGFloat(bestCols - 1) * gap + padding * 2
        let contentH = CGFloat(bestRows) * cellH + CGFloat(bestRows - 1) * gap + padding * 2
        let panelW = min(contentW, maxPanelW)
        let panelH = min(contentH, maxPanelH)

        return AltTabLayout(
            columns: bestCols,
            rows: bestRows,
            thumbnailSize: CGSize(width: bestThumbW.rounded(.down), height: thumbH.rounded(.down)),
            panelSize: CGSize(width: panelW.rounded(.up), height: panelH.rounded(.up)),
            contentSize: CGSize(width: max(contentW, panelW).rounded(.up), height: max(contentH, panelH).rounded(.up)),
            needsScroll: contentH > maxPanelH,
            padding: padding,
            gap: gap,
            labelHeight: labelHeight,
            labelGap: labelGap
        )
    }

    private func representativeAspectRatio(for windows: [WindowInfo]) -> CGFloat {
        let ratios = windows.compactMap { win -> CGFloat? in
            guard win.bounds.width > 0, win.bounds.height > 0 else { return nil }
            return min(2.0, max(1.15, win.bounds.width / win.bounds.height))
        }.sorted()
        guard !ratios.isEmpty else { return 1.6 }
        return ratios[ratios.count / 2]
    }

    private func preferredScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    private func buildGrid(in cv: NSView, layout: AltTabLayout, isDark: Bool) {
        thumbnailViews.forEach { $0.removeFromSuperview() }; labelViews.forEach { $0.removeFromSuperview() }; iconViews.forEach { $0.removeFromSuperview() }
        thumbnailViews.removeAll(); thumbnailViewsByWindowID.removeAll(); labelViews.removeAll(); iconViews.removeAll(); tileViews.removeAll()

        let thumbW = layout.thumbnailSize.width
        let thumbH = layout.thumbnailSize.height
        let cellW = thumbW + layout.gap; let cellH = thumbH + layout.labelGap + layout.labelHeight
        let totalGridW = CGFloat(layout.columns) * cellW - layout.gap
        let startX = layout.padding + (cv.bounds.width - layout.padding * 2 - totalGridW) / 2

        let bg = isDark ? NSColor.black.withAlphaComponent(0.3).cgColor : NSColor.white.withAlphaComponent(0.4).cgColor
        let border = isDark ? NSColor.white.withAlphaComponent(0.15).cgColor : NSColor.black.withAlphaComponent(0.12).cgColor
        let textColor = isDark ? NSColor.white : NSColor.black

        for (i, win) in windows.enumerated() {
            let col = i % layout.columns; let row = i / layout.columns
            let slotX = startX + CGFloat(col) * cellW
            let baseY = cv.bounds.height - layout.padding - CGFloat(row + 1) * cellH - CGFloat(row) * layout.gap
            let windowAspect = max(0.65, min(2.2, win.bounds.width / max(win.bounds.height, 1)))
            let cardAspect = thumbW / max(thumbH, 1)
            let minTileW = min(thumbW, max(170, thumbW * 0.58))
            let aspectWidth = min(thumbW, thumbH * windowAspect)
            let tileThumbW = windowAspect < cardAspect * 1.08
                ? max(minTileW, aspectWidth)
                : thumbW
            let x = slotX + (thumbW - tileThumbW) / 2

            let cell = ThumbnailTileView(frame: NSRect(x: x, y: baseY, width: tileThumbW, height: cellH))
            cell.index = i
            cell.onClick = { [weak self] index in
                guard let self = self, index < self.windows.count else { return }
                self.selectedIndex = index
                self.updateSelection()
                self.activateSelectedAndHide(keepOptionReleaseFromReactivating: true)
            }
            cv.addSubview(cell); tileViews.append(cell)

            let container = NSView(frame: NSRect(x: 0, y: layout.labelHeight + layout.labelGap, width: tileThumbW, height: thumbH))
            container.wantsLayer = true
            container.layer?.cornerRadius = 8; container.layer?.masksToBounds = true
            container.layer?.borderWidth = i == selectedIndex ? 3 : 1
            container.layer?.borderColor = i == selectedIndex ? NSColor.systemBlue.cgColor : border
            container.layer?.backgroundColor = bg

            let iv = ThumbnailImageView(frame: container.bounds)
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.imageAlignment = .alignCenter
            iv.wantsLayer = true; iv.layer?.masksToBounds = true

            // Cache first, then app icon until ScreenCaptureKit provides the preview.
            if let cached = ThumbnailCache.shared.get(win.windowID) {
                iv.usesAspectFill = true
                iv.image = cached
            } else if let icon = appIcon(for: win) {
                iv.usesAspectFill = false
                icon.size = NSSize(width: tileThumbW * 0.5, height: tileThumbW * 0.5)
                iv.image = icon
            }

            container.addSubview(iv); cell.addSubview(container)
            thumbnailViews.append(iv)
            thumbnailViewsByWindowID[win.windowID] = iv

            let title = win.title.isEmpty ? win.appName : "\(win.appName) — \(win.title)"
            let iconSize = min(16, max(12, layout.labelHeight - 4))
            let iconView = NSImageView(frame: NSRect(x: 0, y: (layout.labelHeight - iconSize) / 2, width: iconSize, height: iconSize))
            iconView.image = appIcon(for: win)
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.imageAlignment = .alignCenter
            cell.addSubview(iconView); iconViews.append(iconView)

            let lbl = NSTextField(labelWithString: title)
            let labelX = iconSize + 6
            lbl.frame = NSRect(x: labelX, y: baseY, width: max(20, tileThumbW - iconSize - 6), height: layout.labelHeight)
            lbl.frame.origin.y = 0
            lbl.alignment = .left; lbl.font = .systemFont(ofSize: max(11, min(13, layout.labelHeight - 6)))
            lbl.textColor = i == selectedIndex ? textColor : textColor.withAlphaComponent(0.55)
            lbl.lineBreakMode = .byTruncatingTail
            cell.addSubview(lbl); labelViews.append(lbl)
        }
    }

    private func appIcon(for window: WindowInfo) -> NSImage? {
        guard let app = NSRunningApplication(processIdentifier: window.pid), let bundleURL = app.bundleURL else { return nil }
        return NSWorkspace.shared.icon(forFile: bundleURL.path)
    }

    // MARK: - Thumbnail Capture

    private func captureThumbnails(thumbW: CGFloat, thumbH: CGFloat) {
        captureTask?.cancel()
        captureTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                for win in self.windows {
                    guard !Task.isCancelled, self.isShowing else { return }
                    if ThumbnailCache.shared.get(win.windowID) != nil { continue }
                    guard let scWin = content.windows.first(where: { $0.windowID == win.windowID }) else { continue }
                    await self.captureScreenshot(scWin, windowID: win.windowID, thumbW: thumbW, thumbH: thumbH)
                }
            } catch { print("Thumbnail error: \(error)") }
        }
    }

    private func startBackgroundRefresh(thumbW: CGFloat, thumbH: CGFloat) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self = self else { return }
            while !Task.isCancelled && self.isShowing {
                for win in self.windows {
                    guard !Task.isCancelled, self.isShowing else { return }
                    if ThumbnailCache.shared.get(win.windowID) == nil {
                        await self.captureSingle(win, thumbW: thumbW, thumbH: thumbH)
                    }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func captureSingle(_ win: WindowInfo, thumbW: CGFloat, thumbH: CGFloat) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let scWin = content.windows.first(where: { $0.windowID == win.windowID }) else { return }
            await captureScreenshot(scWin, windowID: win.windowID, thumbW: thumbW, thumbH: thumbH)
        } catch {}
    }

    private func captureScreenshot(_ scWindow: SCWindow, windowID: CGWindowID, thumbW: CGFloat, thumbH: CGFloat) async {
        do {
            let config = SCStreamConfiguration()
            let windowSize = scWindow.frame.size
            let scale = min(2, max(0.25, min((thumbW * 2) / max(windowSize.width, 1), (thumbH * 2) / max(windowSize.height, 1))))
            config.width = max(1, Int(windowSize.width * scale))
            config.height = max(1, Int(windowSize.height * scale))
            config.showsCursor = false
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            ThumbnailCache.shared.set(windowID, image: image)
            DispatchQueue.main.async { [weak self] in self?.updateThumbnail(windowID: windowID, image: image) }
        } catch {}
    }

    func getVisibleApps() -> [String] {
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let name = app.localizedName, !name.isEmpty else { return nil }
            return name
        }.sorted()
    }

    private func updateSelection() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let text = isDark ? NSColor.white : NSColor.black
        let bd = isDark ? NSColor.white.withAlphaComponent(0.15).cgColor : NSColor.black.withAlphaComponent(0.12).cgColor
        for (i, v) in thumbnailViews.enumerated() {
            v.superview?.layer?.borderWidth = i == selectedIndex ? 3 : 1
            v.superview?.layer?.borderColor = i == selectedIndex ? NSColor.systemBlue.cgColor : bd
        }
        for (i, l) in labelViews.enumerated() { l.textColor = i == selectedIndex ? text : text.withAlphaComponent(0.55) }
        scrollSelectedTileIntoView()
    }

    private func scrollSelectedTileIntoView() {
        guard selectedIndex < thumbnailViews.count,
              let tile = thumbnailViews[selectedIndex].superview else { return }
        tile.scrollToVisible(tile.bounds.insetBy(dx: -12, dy: -12))
    }

    private func activateSelectedAndHide(keepOptionReleaseFromReactivating: Bool = false) {
        if selectedIndex < windows.count { activateWindow(windows[selectedIndex]) }
        if keepOptionReleaseFromReactivating { optionKeyHeld = false }
        hideAltTab()
    }

    private func handleSwitcherMouseDown(at screenPoint: CGPoint) -> Bool {
        if Thread.isMainThread {
            return activateTile(at: NSEvent.mouseLocation) || activateTile(at: screenPoint)
        }

        var handled = false
        DispatchQueue.main.sync { handled = activateTile(at: NSEvent.mouseLocation) || activateTile(at: screenPoint) }
        return handled
    }

    private func handleSwitcherMouseMoved(at screenPoint: CGPoint) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let appKitPoint = NSEvent.mouseLocation
            guard self.shouldAllowMouseSelection(at: appKitPoint),
                  let tile = self.tile(at: appKitPoint),
                  tile.index < self.windows.count,
                  tile.index != self.selectedIndex else { return }
            self.selectedIndex = tile.index
            self.updateSelection()
        }
    }

    private func shouldAllowMouseSelection(at point: CGPoint) -> Bool {
        if mouseSelectionEnabled { return true }
        guard let initialMouseLocation else {
            mouseSelectionEnabled = true
            return true
        }
        let dx = point.x - initialMouseLocation.x
        let dy = point.y - initialMouseLocation.y
        if hypot(dx, dy) > 16 {
            mouseSelectionEnabled = true
        }
        return mouseSelectionEnabled
    }

    private func activateTile(at screenPoint: CGPoint) -> Bool {
        if let tile = tile(at: screenPoint) {
            return activate(tile)
        }
        guard let primaryFrame = NSScreen.screens.first?.frame else { return false }
        let flippedPoint = CGPoint(x: screenPoint.x, y: primaryFrame.maxY - screenPoint.y)
        guard let tile = tile(at: flippedPoint) else { return false }
        return activate(tile)
    }

    private func tile(at screenPoint: CGPoint) -> ThumbnailTileView? {
        guard isShowing,
              let panel = altTabPanel,
              panel.frame.contains(screenPoint) else { return nil }

        return tileViews.first { tile in
            let windowRect = tile.convert(tile.bounds, to: nil)
            let screenRect = panel.convertToScreen(windowRect)
            return screenRect.insetBy(dx: -3, dy: -3).contains(screenPoint)
        }
    }

    private func activate(_ tile: ThumbnailTileView) -> Bool {
        guard tile.index < windows.count else { return false }
        selectedIndex = tile.index
        updateSelection()
        activateSelectedAndHide(keepOptionReleaseFromReactivating: true)
        return true
    }

    func hideAltTab() {
        isShowing = false; captureTask?.cancel(); captureTask = nil
        refreshTask?.cancel(); refreshTask = nil
        altTabPanel?.orderOut(nil); altTabPanel = nil
        thumbnailViews.removeAll(); thumbnailViewsByWindowID.removeAll(); labelViews.removeAll(); iconViews.removeAll(); tileViews.removeAll()
    }

    private func activateWindow(_ window: WindowInfo) {
        let app = NSRunningApplication(processIdentifier: window.pid)
        app?.activate(options: [])
        guard let axWindow = axWindow(for: window) else { return }
        AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        let axApp = AXUIElementCreateApplication(window.pid)
        AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, axWindow)
    }

    private func axWindow(for window: WindowInfo) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(window.pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let axWindows = value as? [AXUIElement] else { return nil }

        for axWindow in axWindows {
            var numberValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWindow, "AXWindowNumber" as CFString, &numberValue) == .success,
               let number = numberValue as? NSNumber,
               number.uint32Value == window.windowID {
                return axWindow
            }
        }

        return axWindows.first { axWindow in
            var titleValue: CFTypeRef?
            guard !window.title.isEmpty,
                  AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleValue) == .success,
                  let title = titleValue as? String else { return false }
            return title == window.title
        }
    }

    @objc private func screenParametersChanged() {
        guard isShowing else { return }
        DispatchQueue.main.async { [weak self] in self?.renderPanel(restartCapture: false) }
    }

    // MARK: - Window Enumeration (ALL windows, no dedup)

    private func getWindows() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var result: [WindowInfo] = []
        for d in list {
            guard let wid = d[kCGWindowNumber as String] as? CGWindowID,
                  let bd = d[kCGWindowBounds as String] as? [String: CGFloat],
                  let al = d[kCGWindowAlpha as String] as? Double,
                  let ly = d[kCGWindowLayer as String] as? Int,
                  let pid = d[kCGWindowOwnerPID as String] as? pid_t,
                  let own = d[kCGWindowOwnerName as String] as? String else { continue }
            guard al > 0.01, ly <= 2, !AltTabSettings.shared.excludedAppNames.contains(own) else { continue }
            let b = CGRect(x: bd["X"] ?? 0, y: bd["Y"] ?? 0, width: bd["Width"] ?? 0, height: bd["Height"] ?? 0)
            guard b.width > 50, b.height > 50 else { continue }
            // NO dedup — show ALL windows, even same app
            result.append(WindowInfo(windowID: wid, title: d[kCGWindowName as String] as? String ?? "", appName: own, bounds: b, pid: pid, alpha: al, windowLayer: ly))
        }
        return result.sorted { ($0.appName, $0.title) < ($1.appName, $1.title) }
    }
}

extension AltTabManager {
    func updateThumbnail(windowID: CGWindowID, image: NSImage) {
        guard isShowing, let thumbnailView = thumbnailViewsByWindowID[windowID] else { return }
        thumbnailView.usesAspectFill = true
        thumbnailView.image = image
    }
}

private class ThumbnailImageView: NSImageView {
    var usesAspectFill = false {
        didSet { needsDisplay = true }
    }

    override var image: NSImage? {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard usesAspectFill, let image else {
            super.draw(dirtyRect)
            return
        }

        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return }

        let imageAspect = imageSize.width / imageSize.height
        let viewAspect = bounds.width / bounds.height
        let aspectDelta = max(imageAspect, viewAspect) / max(0.01, min(imageAspect, viewAspect))

        if aspectDelta > 1.20 {
            drawAspectFitPreview(image, imageSize)
            return
        }

        let drawSourceRect: NSRect
        if imageAspect > viewAspect {
            let cropWidth = imageSize.height * viewAspect
            drawSourceRect = NSRect(x: (imageSize.width - cropWidth) / 2, y: 0, width: cropWidth, height: imageSize.height)
        } else {
            let cropHeight = imageSize.width / viewAspect
            drawSourceRect = NSRect(x: 0, y: (imageSize.height - cropHeight) / 2, width: imageSize.width, height: cropHeight)
        }

        image.draw(in: bounds, from: drawSourceRect, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }

    private func drawAspectFitPreview(_ image: NSImage, _ imageSize: NSSize) {
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let fittedSize = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let fittedRect = NSRect(
            x: (bounds.width - fittedSize.width) / 2,
            y: (bounds.height - fittedSize.height) / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )

        image.draw(in: fittedRect, from: NSRect(origin: .zero, size: imageSize), operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }
}

private class ThumbnailTileView: NSView {
    var index = 0
    var onClick: ((Int) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(index)
    }
}

private class ScreenRecordingProbeHandler: NSObject, SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}
}