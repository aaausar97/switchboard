import AVFoundation
import Cocoa
import Foundation
import ScreenCaptureKit

/// Records system audio via ScreenCaptureKit's SCStream.
/// Saves to ~/Downloads/Switchboard Recordings/ as .m4a files.
class SystemAudioRecorder: NSObject {
    private var stream: SCStream?
    private var audioWriter: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var timer: Timer?
    private var startTime: Date?
    private var isRecording = false
    private var outputURL: URL?

    /// Starts recording.
    /// - Parameters:
    ///   - onStart: Called on the main thread once the stream is running.
    ///   - onError: Called on the main thread if setup fails (e.g. permission denied).
    func startRecording(onStart: (() -> Void)? = nil, onError: (() -> Void)? = nil) {
        guard !isRecording else { return }

        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let dir = downloads.appendingPathComponent("Switchboard Recordings")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = dir.appendingPathComponent("recording_\(df.string(from: Date())).m4a")
        outputURL = url

        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = content.displays.first else {
                    DispatchQueue.main.async { onError?() }
                    return
                }

                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true

                let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global())
                try await stream.startCapture()
                self.stream = stream

                let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVNumberOfChannelsKey: 2,
                    AVSampleRateKey: 48000,
                    AVEncoderBitRateKey: 128000
                ]
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
                input.expectsMediaDataInRealTime = true
                writer.add(input)
                writer.startWriting()
                writer.startSession(atSourceTime: .zero)
                self.audioWriter = writer
                self.audioInput = input

                self.startTime = Date()
                self.isRecording = true
                AppState.shared.isRecording = true
                AppState.shared.lastRecordingURL = url

                let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                    guard let start = self?.startTime else { return }
                    AppState.shared.recordingDuration = Date().timeIntervalSince(start)
                }
                RunLoop.main.add(t, forMode: .common)
                self.timer = t

                print("Recording started: \(url.path)")
                // Always deliver callbacks on the main thread — callers update UI.
                DispatchQueue.main.async { onStart?() }
            } catch {
                print("Recording setup failed: \(error.localizedDescription)")
                DispatchQueue.main.async { onError?() }
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }

        // Update shared state immediately so the UI reflects the stop at once.
        isRecording = false
        AppState.shared.isRecording = false
        AppState.shared.recordingDuration = 0
        timer?.invalidate(); timer = nil

        // Capture references and clear instance vars so a new recording can start
        // without waiting for the async teardown to finish.
        let capturedStream = stream
        let capturedInput = audioInput
        let capturedWriter = audioWriter
        let capturedURL = outputURL
        stream = nil; audioInput = nil; audioWriter = nil

        Task {
            // Stop the SCStream first — this prevents any further audio samples
            // from arriving at the writer after we mark the input as finished.
            try? await capturedStream?.stopCapture()

            capturedInput?.markAsFinished()

            if let writer = capturedWriter {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    writer.finishWriting { cont.resume() }
                }
            }

            print("Recording saved: \(capturedURL?.path ?? "unknown")")
        }
    }
}

extension SystemAudioRecorder: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio,
              let input = audioInput,
              input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }
}
