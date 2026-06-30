import ApplicationServices
import AVFoundation
import Cocoa

// ponytail: one model, whisper-cli subprocess — add parakeet/moonshine when a second engine is worth owning
final class DictationManager: NSObject {
    static let minHoldDuration: TimeInterval = 0.3

    private let modelPath = NSHomeDirectory() + "/.whisper/models/ggml-small.bin"
    private let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var startedAt: Date?
    private var overlay = DictationOverlay()
    private var transcribeProcess: Process?

    private(set) var isRecording = false
    private(set) var isTranscribing = false

    var setupIssue: (detail: String, tooltip: String)? {
        if findWhisperCLI() == nil {
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
        guard findWhisperCLI() != nil else {
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
            overlay.show("Listening…")
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
        overlay.show("Transcribing…")

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

        guard let cli = findWhisperCLI() else { return }

        let outBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("switchboard-out-\(UUID().uuidString)").path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["-m", modelPath, "-f", wav.path, "-of", outBase, "-otxt", "-nt", "-l", "en"]
        let errPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errPipe

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

    private func findWhisperCLI() -> String? {
        for dir in searchPaths {
            let path = "\(dir)/whisper-cli"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}

// MARK: - Bottom overlay

private final class DictationOverlay {
    private var panel: NSPanel?
    private var effectView: NSVisualEffectView?
    private var label: NSTextField?
    private var dot: NSView?
    private var flashTimer: Timer?

    private let font = NSFont.systemFont(ofSize: 13, weight: .medium)
    private let dotSize: CGFloat = 7
    private let gap: CGFloat = 8
    private let padH: CGFloat = 24
    private let padV: CGFloat = 12
    private let rowHeight: CGFloat = 18

    func show(_ text: String) {
        DispatchQueue.main.async { [self] in
            flashTimer?.invalidate()
            flashTimer = nil
            let p = panel ?? makePanel()
            panel = p
            layout(text: text, isError: false)
            p.orderFrontRegardless()
        }
    }

    func flash(_ text: String) {
        DispatchQueue.main.async { [self] in
            let p = panel ?? makePanel()
            panel = p
            layout(text: text, isError: true)
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

    private func layout(text: String, isError: Bool) {
        guard let p = panel, let effect = effectView, let dot, let label else { return }

        label.stringValue = text
        label.font = font
        label.textColor = isError ? .secondaryLabelColor : .labelColor
        label.alignment = .center

        let visible = overlayVisibleFrame()
        let maxTextW = max(120, visible.width * 0.72 - padH * 2)
        let showDot = !isError
        let availableTextW = showDot ? maxTextW - dotSize - gap : maxTextW

        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let naturalW = ceil((text as NSString).size(withAttributes: attrs).width)
        let wraps = naturalW > availableTextW

        label.lineBreakMode = wraps ? .byWordWrapping : .byClipping
        label.maximumNumberOfLines = wraps ? 2 : 1

        let textW = wraps
            ? availableTextW
            : min(naturalW + 4, availableTextW)
        let textH = wraps
            ? ceil((text as NSString).boundingRect(
                with: CGSize(width: textW, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attrs,
                context: nil
            ).height)
            : rowHeight

        let contentW = (showDot ? dotSize + gap : 0) + textW
        let width = min(visible.width - 48, max(168, contentW + padH * 2))
        let height = max(40, textH + padV * 2)

        let frame = NSRect(x: visible.midX - width / 2, y: visible.minY + 32, width: width, height: height)
        p.setFrame(frame, display: true)
        effect.frame = NSRect(origin: .zero, size: frame.size)
        effect.layer?.cornerRadius = height / 2

        let startX = (width - contentW) / 2
        let blockTop = (height - textH) / 2

        dot.isHidden = !showDot
        if showDot {
            dot.frame = NSRect(x: startX, y: blockTop + (textH - dotSize) / 2, width: dotSize, height: dotSize)
            dot.layer?.backgroundColor = dotColor(for: text, isError: isError).cgColor
        }

        let labelX = showDot ? startX + dotSize + gap : startX
        label.frame = NSRect(x: labelX, y: blockTop, width: textW, height: textH)
    }

    private func dotColor(for text: String, isError: Bool) -> NSColor {
        if isError { return .systemYellow }
        if text.hasPrefix("Transcrib") { return .systemOrange }
        return .systemRed
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
        effect.layer?.cornerRadius = 20
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        effectView = effect

        let dotView = NSView(frame: .zero)
        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = dotSize / 2
        effect.addSubview(dotView)
        dot = dotView

        let lbl = NSTextField(labelWithString: "")
        lbl.font = font
        lbl.isBezeled = false
        lbl.drawsBackground = false
        lbl.isEditable = false
        lbl.lineBreakMode = .byClipping
        lbl.alignment = .center
        lbl.cell?.truncatesLastVisibleLine = false
        effect.addSubview(lbl)
        label = lbl

        p.contentView = effect
        return p
    }
}
