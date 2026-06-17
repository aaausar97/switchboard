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

    func startRecording(completion: (() -> Void)? = nil) {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let dir = downloads.appendingPathComponent("Switchboard Recordings")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = dir.appendingPathComponent("recording_\(df.string(from: Date())).m4a")
        outputURL = url

        Task {
            do {
                // Get display for audio capture
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = content.displays.first else { return }

                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true

                let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global())
                try await stream.startCapture()
                self.stream = stream

                // AVAssetWriter for M4A output
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

                // Duration timer
                let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                    guard let start = self?.startTime else { return }
                    AppState.shared.recordingDuration = Date().timeIntervalSince(start)
                }
                RunLoop.main.add(t, forMode: .common)
                self.timer = t

                print("Recording started: \(url.path)")
                completion?()
            } catch {
                // Just log — system will show its own permission prompt if needed
                print("Recording setup failed: \(error.localizedDescription)")
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        timer?.invalidate(); timer = nil

        Task { try? await stream?.stopCapture(); stream = nil }

        audioInput?.markAsFinished()
        audioWriter?.finishWriting { [weak self] in
            self?.audioWriter = nil
            self?.audioInput = nil
        }

        isRecording = false
        AppState.shared.isRecording = false
        AppState.shared.recordingDuration = 0
        print("Recording stopped: \(outputURL?.path ?? "unknown")")
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
