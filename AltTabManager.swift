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
    private var capturedAt: [CGWindowID: Date] = [:]
    private let maxEntries = 128
    private let defaultMaxAge: TimeInterval = 1.25

    func get(_ id: CGWindowID) -> NSImage? { cache[id] }

    func isFresh(_ id: CGWindowID, maxAge: TimeInterval? = nil) -> Bool {
        guard let capturedAt = capturedAt[id] else { return false }
        return Date().timeIntervalSince(capturedAt) < (maxAge ?? defaultMaxAge)
    }

    func set(_ id: CGWindowID, image: NSImage) {
        if cache.count >= maxEntries {
            cache.keys.prefix(maxEntries / 2).forEach {
                cache.removeValue(forKey: $0)
                capturedAt.removeValue(forKey: $0)
            }
        }
        cache[id] = image
        capturedAt[id] = Date()
    }

    func remove(_ id: CGWindowID) {
        cache.removeValue(forKey: id)
        capturedAt.removeValue(forKey: id)
    }
}

// MARK: - Settings
class AltTabSettings {
    static let shared = AltTabSettings()

    private static let defaultExclusions: Set<String> = [
        "Stickies", "Window Server", "SystemUIServer",
        "ControlCenter", "Spotlight", "loginwindow",
        "Notification Centre", "NotificationCenter", "Notification Center",
        "Widgets", "WidgetBoard", "widgetsimulator",
    ]
    private let key = "SwitchboardExcludedApps"

    // didSet writes to UserDefaults so exclusions survive relaunch.
    // Swift calls didSet for in-place Set mutations (insert/remove) too.
    var excludedAppNames: Set<String> {
        didSet { UserDefaults.standard.set(Array(excludedAppNames), forKey: key) }
    }

    private init() {
        if let saved = UserDefaults.standard.array(forKey: key) as? [String] {
            excludedAppNames = Set(saved)
        } else {
            excludedAppNames = Self.defaultExclusions
        }
    }
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
            if !hasScreenRecording {
                requestScreenRecordingForThumbnails()
                DispatchQueue.main.async { showPermissionSetupAlert() }
            }
            return
        }

        onReadyCallbacks.append(onReady)
        requestMissingPermissions()
        showPermissionSetupAlert()
        startPermissionPolling()
    }

    static func showSetupAlertIfNeeded() {
        guard !hasAccessibility || !hasScreenRecording else { return }
        if !hasAccessibility { requestMissingPermissions() }
        if !hasScreenRecording { requestScreenRecordingForThumbnails() }
        showPermissionSetupAlert()
        if !hasAccessibility { startPermissionPolling() }
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
        if !hasScreenRecording {
            requestScreenRecordingForThumbnails()
        }
    }

    private static func showPermissionSetupAlert() {
        let needsAccessibility = !hasAccessibility
        let needsScreenRecording = !hasScreenRecording
        guard !alertIsShowing, needsAccessibility || needsScreenRecording else { return }
        alertIsShowing = true

        let alert = NSAlert()
        alert.messageText = "Switchboard Needs Permissions"
        alert.informativeText = permissionMessage(
            needsAccessibility: needsAccessibility,
            needsScreenRecording: needsScreenRecording
        )
        if needsAccessibility { alert.addButton(withTitle: "Open Accessibility") }
        if needsScreenRecording { alert.addButton(withTitle: "Open Screen Recording") }
        alert.addButton(withTitle: "Check Again")
        alert.addButton(withTitle: "Quit")
        NSApp.activate()
        let response = alert.runModal()
        alertIsShowing = false

        let openedSettings = handlePermissionAlertResponse(response)

        if hasAccessibility {
            finishPermissionSetup()
        }

        guard !hasAccessibility || !hasScreenRecording else { return }

        let delay: TimeInterval = openedSettings ? 8 : 0.75
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            showPermissionSetupAlert()
        }
    }

    @discardableResult
    private static func handlePermissionAlertResponse(_ response: NSApplication.ModalResponse) -> Bool {
        var buttonIndex = 1
        var openedSettings = false
        if !hasAccessibility {
            if response.rawValue == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + buttonIndex - 1 {
                openPrivacyPane("Privacy_Accessibility")
                openedSettings = true
            }
            buttonIndex += 1
        }
        if !hasScreenRecording {
            if response.rawValue == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + buttonIndex - 1 {
                requestScreenRecordingForThumbnails()
                openPrivacyPane("Privacy_ScreenCapture")
                openedSettings = true
            }
            buttonIndex += 1
        }
        if response.rawValue == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + buttonIndex {
            NSApp.terminate(nil)
        }
        return openedSettings
    }

    private static func permissionMessage(needsAccessibility: Bool, needsScreenRecording: Bool) -> String {
        var lines: [String] = []
        if needsAccessibility {
            lines.append("Option-Tab needs Accessibility to listen for the keyboard shortcut and switch windows.")
        }
        if needsScreenRecording {
            lines.append("Screen Recording is needed for live window thumbnails and system audio capture.")
        }
        if needsAccessibility && needsScreenRecording {
            lines.append("")
            lines.append("Grant Accessibility first, then Screen Recording.")
        }
        return lines.joined(separator: "\n")
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
    private var thumbnailViews: [NSImageView] = []
    private var thumbnailViewsByWindowID: [CGWindowID: NSImageView] = [:]
    private var labelViews: [NSTextField] = []
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
    private var closeHotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var permissionMonitorTimer: Timer?
    private var isHandlingPermissionLoss = false
    private var optimisticallyClosingWindowIDs = Set<CGWindowID>()
    private var dismissSwitcherOnOptionRelease = false
    private var dictationSpaceHeld = false

    var onOptionSpaceDown: (() -> Void)?
    var onOptionSpaceUp: (() -> Void)?
    var onOptionReleasedDuringDictation: (() -> Void)?

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
        teardownHotkeyMonitoring(stopPermissionMonitor: true)
        NotificationCenter.default.removeObserver(self)
    }

    func registerHotkey() {
        guard SwitchboardPermissions.hasAccessibility else {
            startPermissionMonitor()
            return
        }
        guard eventTap == nil else { return }
        let mask = CGEventMask(
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
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
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            self?.handleGlobalNSEvent(event)
        }
        registerCarbonHotkey()
        startPermissionMonitor()
        print("Switchboard: hotkey ready")
    }

    private func startPermissionMonitor() {
        guard permissionMonitorTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.syncPermissionState()
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionMonitorTimer = timer
    }

    private func syncPermissionState() {
        if SwitchboardPermissions.hasAccessibility {
            isHandlingPermissionLoss = false
            if eventTap == nil {
                registerHotkey()
            }
            return
        }

        handleAccessibilityRevoked()
    }

    private func handleAccessibilityRevoked() {
        guard !isHandlingPermissionLoss else { return }
        isHandlingPermissionLoss = true
        hideAltTab()
        optionKeyHeld = false
        isProcessingHotkey = false
        teardownHotkeyMonitoring(stopPermissionMonitor: false)
        print("Switchboard: Accessibility permission revoked; released keyboard and mouse hooks")
    }

    private func teardownHotkeyMonitoring(stopPermissionMonitor: Bool) {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
        }
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let closeHotKeyRef {
            UnregisterEventHotKey(closeHotKeyRef)
        }
        if let hotKeyHandler {
            RemoveEventHandler(hotKeyHandler)
        }
        eventTap = nil
        eventTapSource = nil
        globalKeyMonitor = nil
        hotKeyRef = nil
        closeHotKeyRef = nil
        hotKeyHandler = nil

        if stopPermissionMonitor {
            permissionMonitorTimer?.invalidate()
            permissionMonitorTimer = nil
        }
    }

    private func registerCarbonHotkey() {
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData else { return noErr }
                let manager = Unmanaged<AltTabManager>.fromOpaque(userData).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }

                switch hotKeyID.id {
                case 1:
                    manager.triggerOptionTab()
                case 2:
                    manager.triggerOptionW()
                default:
                    break
                }
                return noErr
            },
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &hotKeyHandler
        )

        let hotKeyID = EventHotKeyID(signature: Self.fourCharCode("SWBD"), id: 1)
        RegisterEventHotKey(UInt32(kVK_Tab), UInt32(optionKey), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        let closeHotKeyID = EventHotKeyID(signature: Self.fourCharCode("SWBD"), id: 2)
        RegisterEventHotKey(UInt32(kVK_ANSI_W), UInt32(optionKey), closeHotKeyID, GetApplicationEventTarget(), 0, &closeHotKeyRef)
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
                    if SwitchboardPermissions.hasAccessibility {
                        if let tap = manager.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                    } else {
                        DispatchQueue.main.async { manager.handleAccessibilityRevoked() }
                    }
                    return Unmanaged.passRetained(event)
                }
                return manager.handleCGEvent(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
    }

    private func handleGlobalNSEvent(_ event: NSEvent) {
        if event.type == .flagsChanged {
            handleModifierFlagsChanged(optionDown: event.modifierFlags.contains(.option))
            return
        }
        if event.type == .keyDown,
           event.keyCode == 13,
           event.modifierFlags.contains(.option),
           isShowing {
            DispatchQueue.main.async { [weak self] in self?.closeSelectedWindow() }
            return
        }
        if !isShowing, event.modifierFlags.contains(.option), event.keyCode == 49 {
            if event.type == .keyDown {
                dictationSpaceHeld = true
                DispatchQueue.main.async { [weak self] in self?.onOptionSpaceDown?() }
            } else if event.type == .keyUp, dictationSpaceHeld {
                dictationSpaceHeld = false
                DispatchQueue.main.async { [weak self] in self?.onOptionSpaceUp?() }
            }
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

    private func triggerOptionW() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isShowing else { return }
            self.closeSelectedWindow()
        }
    }

    private func handleCGEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard SwitchboardPermissions.hasAccessibility else {
            DispatchQueue.main.async { [weak self] in self?.handleAccessibilityRevoked() }
            return Unmanaged.passRetained(event)
        }

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
            if !optionNow, dictationSpaceHeld {
                dictationSpaceHeld = false
                DispatchQueue.main.async { [weak self] in self?.onOptionReleasedDuringDictation?() }
                return nil
            }
            if handleModifierFlagsChanged(optionDown: optionNow) {
                return nil
            }
            return Unmanaged.passRetained(event)
        }
        if type == .keyUp {
            let kc = event.getIntegerValueField(.keyboardEventKeycode)
            if kc == 49, dictationSpaceHeld {
                dictationSpaceHeld = false
                DispatchQueue.main.async { [weak self] in self?.onOptionSpaceUp?() }
                return nil
            }
        }
        if type == .keyDown {
            let kc = event.getIntegerValueField(.keyboardEventKeycode)
            let optionDown = event.flags.contains(.maskAlternate) || optionKeyHeld
            if !isShowing, optionDown, kc == 49 {
                dictationSpaceHeld = true
                DispatchQueue.main.async { [weak self] in self?.onOptionSpaceDown?() }
                return nil
            }
            if optionDown && kc == 48 {
                triggerOptionTab()
                return nil
            }
            if optionDown && kc == 13, isShowing {
                DispatchQueue.main.async { [weak self] in self?.closeSelectedWindow() }
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
        dismissSwitcherOnOptionRelease = false
        selectedIndex = 0; isShowing = true
        renderPanel(restartCapture: true)
    }

    @discardableResult
    private func handleModifierFlagsChanged(optionDown: Bool) -> Bool {
        if isShowing && !optionDown && (dismissSwitcherOnOptionRelease || optionKeyHeld) {
            dismissSwitcherOnOptionRelease = false
            optionKeyHeld = false
            DispatchQueue.main.async { [weak self] in self?.activateSelectedAndHide() }
            return true
        }
        optionKeyHeld = optionDown
        return false
    }

    private func renderPanel(restartCapture: Bool, animated: Bool = false) {
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
        } else if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
        panel.isOpaque = false
        panel.hasShadow = false
        panel.backgroundColor = .clear

        let gridView = NSView(frame: NSRect(origin: .zero, size: layout.contentSize))
        gridView.wantsLayer = true
        gridView.layer?.cornerRadius = 18
        gridView.layer?.masksToBounds = false
        buildGrid(in: gridView, layout: layout, isDark: isDark)

        let backdrop = makePanelBackdrop(size: layout.panelSize, isDark: isDark)
        if layout.needsScroll {
            let scroll = NSScrollView(frame: NSRect(origin: .zero, size: layout.panelSize))
            scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
            scroll.autohidesScrollers = true
            scroll.borderType = .noBorder
            scroll.drawsBackground = false
            scroll.documentView = gridView
            backdrop.addSubview(scroll)
            let topOrigin = max(0, layout.contentSize.height - layout.panelSize.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: topOrigin))
            scroll.reflectScrolledClipView(scroll.contentView)
        } else {
            backdrop.addSubview(gridView)
        }
        panel.contentView = backdrop

        panel.orderFrontRegardless(); panel.makeKey(); altTabPanel = panel

        if restartCapture && SwitchboardPermissions.hasScreenRecording {
            captureThumbnails(thumbW: layout.thumbnailSize.width, thumbH: layout.thumbnailSize.height)
            startBackgroundRefresh(thumbW: layout.thumbnailSize.width, thumbH: layout.thumbnailSize.height)
        }
    }

    private func makePanelBackdrop(size: CGSize, isDark: Bool) -> NSView {
        let shell = NSView(frame: NSRect(origin: .zero, size: size))
        shell.wantsLayer = true
        shell.layer?.cornerRadius = 22
        shell.layer?.masksToBounds = false
        shell.layer?.shadowColor = NSColor.black.cgColor
        shell.layer?.shadowOpacity = isDark ? 0.34 : 0.18
        shell.layer?.shadowRadius = 28
        shell.layer?.shadowOffset = CGSize(width: 0, height: -10)

        let backdrop = NSVisualEffectView(frame: shell.bounds)
        backdrop.autoresizingMask = [.width, .height]
        backdrop.blendingMode = .behindWindow
        backdrop.material = .popover
        backdrop.state = .active
        backdrop.alphaValue = isDark ? 0.94 : 0.96
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 22
        backdrop.layer?.masksToBounds = true
        backdrop.layer?.borderWidth = 0.5
        backdrop.layer?.borderColor = NSColor.white.withAlphaComponent(isDark ? 0.14 : 0.22).cgColor
        shell.addSubview(backdrop)

        let wash = NSView(frame: backdrop.bounds)
        wash.autoresizingMask = [.width, .height]
        wash.wantsLayer = true
        wash.layer?.backgroundColor = panelWashColor(isDark: isDark).cgColor
        backdrop.addSubview(wash)

        let sheen = NSView(frame: backdrop.bounds)
        sheen.autoresizingMask = [.width, .height]
        sheen.wantsLayer = true
        let gradient = CAGradientLayer()
        gradient.frame = sheen.bounds
        gradient.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        gradient.colors = [
            NSColor.clear.cgColor,
            NSColor.white.withAlphaComponent(isDark ? 0.03 : 0.06).cgColor,
            NSColor.white.withAlphaComponent(isDark ? 0.06 : 0.10).cgColor,
        ]
        gradient.locations = [0, 0.55, 1]
        sheen.layer?.addSublayer(gradient)
        backdrop.addSubview(sheen)

        return shell
    }

    private func panelWashColor(isDark: Bool) -> NSColor {
        if isDark {
            return NSColor(white: 0.07, alpha: 0.09)
        }
        return NSColor.white.withAlphaComponent(0.07)
    }

    private func labelTextColor(selected: Bool, isDark: Bool) -> NSColor {
        if isDark {
            return selected
                ? NSColor.white.withAlphaComponent(0.94)
                : NSColor.white.withAlphaComponent(0.52)
        }
        return selected
            ? NSColor.black.withAlphaComponent(0.90)
            : NSColor.black.withAlphaComponent(0.46)
    }

    private func labelParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        return style
    }

    private func labelAttributes(
        font: NSFont,
        color: NSColor,
        kern: CGFloat = -0.15
    ) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: color,
            .kern: kern,
            .paragraphStyle: labelParagraphStyle(),
        ]
    }

    private func styledWindowLabel(_ title: String, selected: Bool, isDark: Bool) -> NSAttributedString {
        let fontSize: CGFloat = 11.5
        let primary = labelTextColor(selected: selected, isDark: isDark)
        let separator = " — "

        if let sepRange = title.range(of: separator) {
            let appName = String(title[..<sepRange.lowerBound])
            let windowTitle = String(title[sepRange.upperBound...])
            let result = NSMutableAttributedString()
            result.append(NSAttributedString(string: appName, attributes: labelAttributes(
                font: .systemFont(ofSize: fontSize, weight: selected ? .semibold : .medium),
                color: primary
            )))
            result.append(NSAttributedString(string: separator, attributes: labelAttributes(
                font: .systemFont(ofSize: fontSize, weight: .regular),
                color: primary.withAlphaComponent(0.32)
            )))
            result.append(NSAttributedString(string: windowTitle, attributes: labelAttributes(
                font: .systemFont(ofSize: fontSize, weight: .regular),
                color: primary.withAlphaComponent(selected ? 0.86 : 0.62)
            )))
            return result
        }

        return NSAttributedString(string: title, attributes: labelAttributes(
            font: .systemFont(ofSize: fontSize, weight: selected ? .semibold : .regular),
            color: primary
        ))
    }

    private func applyLabelStyle(_ label: NSTextField, title: String, selected: Bool, isDark: Bool) {
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.attributedStringValue = styledWindowLabel(title, selected: selected, isDark: isDark)
    }

    private func applySelectionStyle(to thumbnailContainer: NSView?, selected: Bool) {
        thumbnailContainer?.layer?.shadowColor = NSColor.black.cgColor
        thumbnailContainer?.layer?.shadowOpacity = selected ? 0.42 : 0
        thumbnailContainer?.layer?.shadowRadius = selected ? 10 : 0
        thumbnailContainer?.layer?.shadowOffset = CGSize(width: 0, height: -2)
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
            let emptySlots = cols * rows - count
            let score = thumbW * (thumbW / aspect) - CGFloat(emptySlots) * thumbW * 0.22
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
        var maxRowW: CGFloat = 0
        for row in 0..<bestRows {
            let itemsInRow = min(bestCols, count - row * bestCols)
            let rowW = CGFloat(itemsInRow) * bestThumbW + CGFloat(max(0, itemsInRow - 1)) * gap
            maxRowW = max(maxRowW, rowW)
        }
        let contentW = maxRowW + padding * 2
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
        thumbnailViews.forEach { $0.removeFromSuperview() }; labelViews.forEach { $0.removeFromSuperview() }
        thumbnailViews.removeAll(); thumbnailViewsByWindowID.removeAll(); labelViews.removeAll(); tileViews.removeAll()

        let thumbW = layout.thumbnailSize.width
        let thumbH = layout.thumbnailSize.height
        let cellW = thumbW + layout.gap
        let cellH = thumbH + layout.labelGap + layout.labelHeight

        for (i, win) in windows.enumerated() {
            let col = i % layout.columns
            let row = i / layout.columns
            let itemsInRow = min(layout.columns, windows.count - row * layout.columns)
            let rowWidth = CGFloat(itemsInRow) * thumbW + CGFloat(max(0, itemsInRow - 1)) * layout.gap
            let rowStartX = layout.padding + (cv.bounds.width - layout.padding * 2 - rowWidth) / 2
            let slotX = rowStartX + CGFloat(col) * cellW
            let baseY = cv.bounds.height - layout.padding - CGFloat(row + 1) * cellH - CGFloat(row) * layout.gap

            let cell = ThumbnailTileView(frame: NSRect(x: slotX, y: baseY, width: thumbW, height: cellH))
            cell.index = i
            cell.onClick = { [weak self] index in
                guard let self = self, index < self.windows.count else { return }
                self.selectedIndex = index
                self.updateSelection()
                self.activateSelectedAndHide(keepOptionReleaseFromReactivating: true)
            }
            cv.addSubview(cell); tileViews.append(cell)

            let container = NSView(frame: NSRect(x: 0, y: layout.labelHeight + layout.labelGap, width: thumbW, height: thumbH))
            container.wantsLayer = true
            container.layer?.cornerRadius = 10
            container.layer?.masksToBounds = true
            container.layer?.backgroundColor = NSColor.clear.cgColor
            applySelectionStyle(to: container, selected: i == selectedIndex)

            let iv = NSImageView(frame: container.bounds)
            iv.imageAlignment = .alignCenter
            iv.imageScaling = .scaleProportionallyDown

            if let cached = ThumbnailCache.shared.get(win.windowID) {
                iv.image = cached
            } else if let icon = appIcon(for: win) {
                icon.size = NSSize(width: thumbW * 0.5, height: thumbW * 0.5)
                iv.image = icon
            }

            container.addSubview(iv); cell.addSubview(container)
            thumbnailViews.append(iv)
            thumbnailViewsByWindowID[win.windowID] = iv

            let title = win.title.isEmpty ? win.appName : "\(win.appName) — \(win.title)"
            let lbl = NSTextField(labelWithString: "")
            lbl.frame = NSRect(x: 0, y: 0, width: thumbW, height: layout.labelHeight)
            lbl.isBezeled = false
            lbl.drawsBackground = false
            lbl.isEditable = false
            lbl.isSelectable = false
            applyLabelStyle(lbl, title: title, selected: i == selectedIndex, isDark: isDark)
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
                    if ThumbnailCache.shared.isFresh(win.windowID) { continue }
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
            var pass = 0
            while !Task.isCancelled && self.isShowing {
                for win in self.windows {
                    guard !Task.isCancelled, self.isShowing else { return }
                    let shouldRefresh = pass > 0 || !ThumbnailCache.shared.isFresh(win.windowID)
                    guard shouldRefresh else { continue }
                    await self.captureSingle(win, thumbW: thumbW, thumbH: thumbH)
                }
                pass += 1
                try? await Task.sleep(nanoseconds: 1_250_000_000)
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
        for attempt in 0..<2 {
            if let image = await captureScreenshotOnce(scWindow, thumbW: thumbW, thumbH: thumbH),
               !isMostlyBlack(image) || attempt == 1 {
                ThumbnailCache.shared.set(windowID, image: image)
                DispatchQueue.main.async { [weak self] in self?.updateThumbnail(windowID: windowID, image: image) }
                return
            }
            if attempt == 0 {
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }

    private func captureScreenshotOnce(_ scWindow: SCWindow, thumbW: CGFloat, thumbH: CGFloat) async -> NSImage? {
        do {
            let config = SCStreamConfiguration()
            let windowSize = scWindow.frame.size
            let scale = min(2, max(0.25, min((thumbW * 2) / max(windowSize.width, 1), (thumbH * 2) / max(windowSize.height, 1))))
            config.width = max(1, Int(windowSize.width * scale))
            config.height = max(1, Int(windowSize.height * scale))
            config.showsCursor = false
            if #available(macOS 14.0, *) {
                config.captureResolution = .best
            }
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return makeDisplayImage(from: cgImage)
        } catch {
            return nil
        }
    }

    private func makeDisplayImage(from cgImage: CGImage) -> NSImage {
        let trimmed = croppedToVisibleContent(cgImage)
        let rep = NSBitmapImageRep(cgImage: trimmed)
        let image = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
        image.addRepresentation(rep)
        return image
    }

    /// Trims uniform dark/empty margins so aspect-fit centers visible window content, not capture padding.
    private func croppedToVisibleContent(_ cgImage: CGImage) -> CGImage {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        guard width > 4, height > 4 else { return cgImage }

        let step = max(1, min(width, height) / 56)
        var minX = width, maxX = 0, minY = height, maxY = 0

        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                guard alpha > 0.04 else { continue }
                guard red > 0.055 || green > 0.055 || blue > 0.055 else { continue }

                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }

        guard maxX > minX, maxY > minY else { return cgImage }

        let pad = max(2, min(width, height) / 72)
        let cropX = max(0, minX - pad)
        let cropY = max(0, minY - pad)
        let cropW = min(width - cropX, maxX - minX + 1 + pad * 2)
        let cropH = min(height - cropY, maxY - minY + 1 + pad * 2)
        let cropRect = CGRect(x: cropX, y: cropY, width: cropW, height: cropH)

        return cgImage.cropping(to: cropRect) ?? cgImage
    }

    private func isMostlyBlack(_ image: NSImage) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return false }

        let sampleSize = 8
        let width = max(1, bitmap.pixelsWide)
        let height = max(1, bitmap.pixelsHigh)
        var darkSamples = 0
        var totalSamples = 0

        for row in 0..<sampleSize {
            for col in 0..<sampleSize {
                let x = col * max(0, width - 1) / max(1, sampleSize - 1)
                let y = row * max(0, height - 1) / max(1, sampleSize - 1)
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                totalSamples += 1
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                if alpha > 0.05, red < 0.08, green < 0.08, blue < 0.08 {
                    darkSamples += 1
                }
            }
        }

        guard totalSamples > 0 else { return false }
        return Double(darkSamples) / Double(totalSamples) > 0.82
    }

    func getVisibleApps() -> [String] {
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let name = app.localizedName, !name.isEmpty else { return nil }
            return name
        }.sorted()
    }

    private func updateSelection() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        for (i, v) in thumbnailViews.enumerated() {
            applySelectionStyle(to: v.superview, selected: i == selectedIndex)
        }
        for (i, l) in labelViews.enumerated() {
            applyLabelStyle(l, title: l.stringValue, selected: i == selectedIndex, isDark: isDark)
        }
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

    private func closeSelectedWindow() {
        guard selectedIndex < windows.count else { return }
        let window = windows[selectedIndex]
        let closedIndex = selectedIndex

        if optimisticallyClosingWindowIDs.contains(window.windowID) { return }

        guard requestWindowClose(window) else {
            NSSound.beep()
            return
        }

        optimisticallyClosingWindowIDs.insert(window.windowID)
        optimisticallyRemoveWindow(at: closedIndex, windowID: window.windowID)
        if isShowing {
            dismissSwitcherOnOptionRelease = true
            optionKeyHeld = CGEventSource.flagsState(.hidSystemState).contains(.maskAlternate)
        }
        confirmWindowClosed(window, closedAtIndex: closedIndex)
    }

    private func optimisticallyRemoveWindow(at index: Int, windowID: CGWindowID) {
        guard index < windows.count, windows[index].windowID == windowID else { return }
        windows.remove(at: index)

        guard !windows.isEmpty else {
            hideAltTab(keepPendingCloseTracking: true)
            return
        }

        selectedIndex = min(index, windows.count - 1)
        renderPanel(restartCapture: false, animated: true)
    }

    private func confirmWindowClosed(_ window: WindowInfo, closedAtIndex: Int, attemptsRemaining: Int = 40) {
        guard optimisticallyClosingWindowIDs.contains(window.windowID) else { return }

        if !isWindowStillVisible(window.windowID) {
            optimisticallyClosingWindowIDs.remove(window.windowID)
            if isShowing {
                reconcileWindowsAfterConfirmedClose()
            }
            return
        }

        guard attemptsRemaining > 0 else {
            optimisticallyClosingWindowIDs.remove(window.windowID)
            rollbackFailedClose(window: window, closedAtIndex: closedAtIndex)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.confirmWindowClosed(window, closedAtIndex: closedAtIndex, attemptsRemaining: attemptsRemaining - 1)
        }
    }

    private func reconcileWindowsAfterConfirmedClose() {
        let fresh = getWindows()
        guard !fresh.isEmpty else {
            hideAltTab()
            return
        }

        let preferredID = selectedIndex < windows.count ? windows[selectedIndex].windowID : nil
        let freshIDs = Set(fresh.map(\.windowID))
        let localIDs = Set(windows.map(\.windowID))

        guard freshIDs != localIDs else { return }

        windows = fresh
        if let preferredID, let idx = windows.firstIndex(where: { $0.windowID == preferredID }) {
            selectedIndex = idx
        } else {
            selectedIndex = min(selectedIndex, windows.count - 1)
        }
        renderPanel(restartCapture: false, animated: false)
    }

    private func rollbackFailedClose(window: WindowInfo, closedAtIndex: Int) {
        guard isWindowStillVisible(window.windowID) else { return }

        let wasHidden = !isShowing
        windows = getWindows()

        guard !windows.isEmpty else {
            hideAltTab()
            return
        }

        guard let restoredIndex = windows.firstIndex(where: { $0.windowID == window.windowID }) else {
            NSSound.beep()
            return
        }

        selectedIndex = restoredIndex
        if wasHidden {
            isShowing = true
        }
        NSSound.beep()
        renderPanel(restartCapture: true, animated: true)
        altTabPanel?.orderFrontRegardless()
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

    func hideAltTab(keepPendingCloseTracking: Bool = false) {
        isShowing = false; captureTask?.cancel(); captureTask = nil
        refreshTask?.cancel(); refreshTask = nil
        dismissSwitcherOnOptionRelease = false
        if !keepPendingCloseTracking {
            optimisticallyClosingWindowIDs.removeAll()
        }
        altTabPanel?.orderOut(nil); altTabPanel = nil
        thumbnailViews.removeAll(); thumbnailViewsByWindowID.removeAll(); labelViews.removeAll(); tileViews.removeAll()
    }

    private func activateWindow(_ window: WindowInfo) {
        let app = NSRunningApplication(processIdentifier: window.pid)
        app?.activate(options: [])
        guard let axWindow = axWindow(for: window) else { return }
        AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        let axApp = AXUIElementCreateApplication(window.pid)
        AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, axWindow)
    }

    private func requestWindowClose(_ window: WindowInfo) -> Bool {
        guard let axWindow = axWindow(for: window) else { return false }
        var closeButtonValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXCloseButtonAttribute as CFString, &closeButtonValue) == .success,
              let closeButtonValue else { return false }
        let closeButton = closeButtonValue as! AXUIElement
        return AXUIElementPerformAction(closeButton, kAXPressAction as CFString) == .success
    }

    private func isWindowStillVisible(_ windowID: CGWindowID) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return list.contains { info in
            (info[kCGWindowNumber as String] as? CGWindowID) == windowID
        }
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

        if let frameMatch = axWindows.first(where: { axWindow in
            guard let frame = axFrame(for: axWindow) else { return false }
            return framesLikelyMatch(frame, window.bounds)
        }) {
            return frameMatch
        }

        return axWindows.first { axWindow in
            var titleValue: CFTypeRef?
            guard !window.title.isEmpty,
                  AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleValue) == .success,
                  let title = titleValue as? String else { return false }
            return title == window.title
        }
    }

    private func axFrame(for axWindow: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue else { return nil }

        let positionAXValue = positionValue as! AXValue
        let sizeAXValue = sizeValue as! AXValue
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAXValue, .cgPoint, &position),
              AXValueGetValue(sizeAXValue, .cgSize, &size) else { return nil }

        return CGRect(origin: position, size: size)
    }

    private func framesLikelyMatch(_ axFrame: CGRect, _ cgFrame: CGRect) -> Bool {
        let tolerance: CGFloat = 36
        let originMatches = abs(axFrame.minX - cgFrame.minX) <= tolerance && abs(axFrame.minY - cgFrame.minY) <= tolerance
        let sizeMatches = abs(axFrame.width - cgFrame.width) <= tolerance && abs(axFrame.height - cgFrame.height) <= tolerance
        return originMatches && sizeMatches
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
        // CGWindowList already returns windows in Z-order (frontmost first).
        // Preserving that order makes the switcher's index 0 = current window,
        // index 1 = most recently used — the standard Alt-Tab behaviour.
        return result
    }
}

extension AltTabManager {
    func updateThumbnail(windowID: CGWindowID, image: NSImage) {
        guard isShowing, let thumbnailView = thumbnailViewsByWindowID[windowID] else { return }
        thumbnailView.image = image
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