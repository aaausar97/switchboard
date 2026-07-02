import ApplicationServices
import AVFoundation
import Cocoa

// ponytail: one model, whisper-cli subprocess — add parakeet/moonshine when a second engine is worth owning
final class DictationManager: NSObject {
    static let minHoldDuration: TimeInterval = 0.3

    private let modelPath = NSHomeDirectory() + "/.whisper/models/ggml-small.bin"

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var startedAt: Date?
    private var overlay = DictationOverlay()
    private var transcribeProcess: Process?

    private(set) var isRecording = false
    private(set) var isTranscribing = false

    var setupIssue: (detail: String, tooltip: String)? {
        if SwitchboardTools.findExecutable("whisper-cli") == nil {
            return (
                detail: "Setup: brew install whisper-cpp",
                tooltip: "whisper-cli not found in /opt/homebrew/bin or /usr/local/bin"
            )
        }
        if !FileManager.default.fileExists(atPath: modelPath) {
            return (
                detail: "Setup: add ggml-small.bin to ~/.whisper/models",
                tooltip: "Download from huggingface.co/ggerganov/whisper.cpp"
            )
        }
        return nil
    }

    func spaceDown() {
        guard !isRecording, !isTranscribing else { return }
        guard SwitchboardTools.findExecutable("whisper-cli") != nil else {
            overlay.flash("Install whisper-cli")
            return
        }
        guard FileManager.default.fileExists(atPath: modelPath) else {
            overlay.flash("Model not found")
            return
        }
        startRecording()
    }

    func spaceUp() {
        guard isRecording else { return }
        stopRecordingAndTranscribe()
    }

    func optionReleased() {
        if isRecording { stopRecordingAndTranscribe() }
    }

    func cancelIfNeeded() {
        recorder?.stop()
        recorder = nil
        transcribeProcess?.terminate()
        transcribeProcess = nil
        isRecording = false
        isTranscribing = false
        overlay.hide()
        cleanupRecordingFile()
    }

    private func startRecording() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("switchboard-dict-\(UUID().uuidString).wav")
        recordingURL = url

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.prepareToRecord()
            guard recorder?.record() == true else {
                overlay.flash("Microphone unavailable")
                cleanupRecordingFile()
                return
            }
            startedAt = Date()
            isRecording = true
            overlay.showListening()
        } catch {
            overlay.flash("Microphone permission required")
            cleanupRecordingFile()
        }
    }

    private func stopRecordingAndTranscribe() {
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        recorder?.stop()
        recorder = nil
        isRecording = false
        startedAt = nil

        guard duration >= Self.minHoldDuration, let wav = recordingURL else {
            overlay.hide()
            cleanupRecordingFile()
            return
        }

        isTranscribing = true
        overlay.showTranscribing()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.transcribe(wav: wav)
        }
    }

    private func transcribe(wav: URL) {
        defer {
            DispatchQueue.main.async { [weak self] in
                self?.isTranscribing = false
                self?.overlay.hide()
            }
            cleanupRecordingFile()
        }

        guard let cli = SwitchboardTools.findExecutable("whisper-cli") else { return }

        let outBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("switchboard-out-\(UUID().uuidString)").path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["-m", modelPath, "-f", wav.path, "-of", outBase, "-otxt", "-nt", "-l", "en"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            transcribeProcess = process
            process.waitUntilExit()
            transcribeProcess = nil
        } catch {
            DispatchQueue.main.async { [weak self] in self?.overlay.flash("Transcription failed") }
            return
        }

        guard process.terminationStatus == 0 else {
            DispatchQueue.main.async { [weak self] in self?.overlay.flash("Transcription failed") }
            return
        }

        let txtPath = outBase + ".txt"
        let text = (try? String(contentsOfFile: txtPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try? FileManager.default.removeItem(atPath: txtPath)

        guard !text.isEmpty else { return }

        DispatchQueue.main.async { [weak self] in
            self?.paste(text)
        }
    }

    private func paste(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        let src = CGEventSource(stateID: .hidSystemState)
        let vDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
        vDown?.flags = .maskCommand
        let vUp = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        vUp?.flags = .maskCommand
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
    }

    private func cleanupRecordingFile() {
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + ".txt")
        }
        recordingURL = nil
    }

}

// MARK: - Bottom overlay

private final class DictationOverlay {
    private enum Mode { case listening, transcribing }

    private var panel: NSPanel?
    private var effectView: NSVisualEffectView?
    private var iconView: NSImageView?
    private var label: NSTextField?
    private var dot: NSView?
    private var flashTimer: Timer?

    private let dotSize: CGFloat = 8
    private let iconSize: CGFloat = 17
    private let gap: CGFloat = 7
    private let pillW: CGFloat = 54
    private let pillH: CGFloat = 38
    private let font = NSFont.systemFont(ofSize: 12, weight: .medium)

    func showListening() { show(.listening) }
    func showTranscribing() { show(.transcribing) }

    func flash(_ text: String) {
        DispatchQueue.main.async { [self] in
            let p = panel ?? makePanel()
            panel = p
            layoutMessage(text)
            p.orderFrontRegardless()
            flashTimer?.invalidate()
            flashTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                self?.hide()
            }
        }
    }

    func hide() {
        DispatchQueue.main.async { [self] in
            flashTimer?.invalidate()
            flashTimer = nil
            panel?.orderOut(nil)
        }
    }

    private func show(_ mode: Mode) {
        DispatchQueue.main.async { [self] in
            flashTimer?.invalidate()
            flashTimer = nil
            let p = panel ?? makePanel()
            panel = p
            layoutIcon(mode)
            p.orderFrontRegardless()
        }
    }

    private func layoutIcon(_ mode: Mode) {
        guard let p = panel, let effect = effectView, let dot, let iconView, let label else { return }

        label.isHidden = true
        iconView.isHidden = false
        dot.isHidden = false

        let symbol = mode == .listening ? "mic.fill" : "text.word.spacing"
        let config = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .medium)
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        iconView.contentTintColor = .labelColor
        dot.layer?.backgroundColor = (mode == .listening ? NSColor.systemRed : NSColor.systemYellow).cgColor

        placePill(width: pillW, height: pillH, on: p, effect: effect)

        let contentW = dotSize + gap + iconSize
        let startX = (pillW - contentW) / 2
        let midY = pillH / 2
        dot.frame = NSRect(x: startX, y: midY - dotSize / 2, width: dotSize, height: dotSize)
        iconView.frame = NSRect(x: startX + dotSize + gap, y: midY - iconSize / 2, width: iconSize, height: iconSize)
    }

    private func layoutMessage(_ text: String) {
        guard let p = panel, let effect = effectView, let dot, let iconView, let label else { return }

        iconView.isHidden = true
        dot.isHidden = true
        label.isHidden = false
        label.stringValue = text
        label.font = font
        label.textColor = .secondaryLabelColor

        let visible = overlayVisibleFrame()
        let maxW = min(320, visible.width * 0.72)
        let textW = min(maxW, ceil((text as NSString).size(withAttributes: [.font: font]).width) + 6)
        let width = max(pillW, textW + 28)
        let height = pillH

        placePill(width: width, height: height, on: p, effect: effect)
        label.frame = NSRect(x: 14, y: (height - 16) / 2, width: width - 28, height: 16)
    }

    private func placePill(width: CGFloat, height: CGFloat, on p: NSPanel, effect: NSVisualEffectView) {
        let visible = overlayVisibleFrame()
        let frame = NSRect(x: visible.midX - width / 2, y: visible.minY + 32, width: width, height: height)
        p.setFrame(frame, display: true)
        effect.frame = NSRect(origin: .zero, size: frame.size)
        effect.layer?.cornerRadius = height / 2
    }

    private func overlayVisibleFrame() -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        return screen?.visibleFrame ?? .zero
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true

        let effect = NSVisualEffectView(frame: .zero)
        effect.autoresizingMask = [.width, .height]
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        effectView = effect

        let dotView = NSView(frame: .zero)
        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = dotSize / 2
        effect.addSubview(dotView)
        dot = dotView

        let icon = NSImageView(frame: .zero)
        icon.imageScaling = .scaleProportionallyDown
        effect.addSubview(icon)
        iconView = icon

        let lbl = NSTextField(labelWithString: "")
        lbl.isBezeled = false
        lbl.drawsBackground = false
        lbl.isEditable = false
        lbl.alignment = .center
        lbl.lineBreakMode = .byTruncatingTail
        lbl.isHidden = true
        effect.addSubview(lbl)
        label = lbl

        p.contentView = effect
        return p
    }
}
