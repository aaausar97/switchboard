import Cocoa
import Foundation

// MARK: - Download State

enum DownloadResult {
    case success(URL)
    case failure(String)
    case cancelled
}

// MARK: - Audio Downloader

/// Downloads audio from a URL to ~/Downloads/Switchboard.
/// Supports direct audio file URLs via URLSession and media page URLs
/// (YouTube, Vimeo, SoundCloud, etc.) via yt-dlp + ffmpeg if installed.
class AudioDownloader: NSObject {
    static let shared = AudioDownloader()

    private(set) var isDownloading = false

    /// Called on the main thread with progress 0.0–1.0, or nil when indeterminate.
    var onProgress: ((Double?) -> Void)?

    private var downloadTask: URLSessionDownloadTask?
    private var ytDlpProcess: Process?
    private var isCancelled = false

    // Direct download state (set before task starts, read by delegate)
    private var completionHandler: ((DownloadResult) -> Void)?
    private var downloadDestination: URL?
    private var directDownloadURL: URL?

    // yt-dlp buffered stdout for error reporting
    private var ytDlpOutputBuffer = ""

    // Delegate-based session so URLSession can report download progress.
    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()

    // MARK: - Public API

    func startDownload(urlString: String, completion: @escaping (DownloadResult) -> Void) {
        guard !isDownloading else {
            completion(.failure("A download is already in progress."))
            return
        }

        let trimmed = sanitizeURLString(urlString)
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              url.scheme == "http" || url.scheme == "https" else {
            completion(.failure("Please enter a valid http or https URL."))
            return
        }

        if isDrmProtected(url: url) {
            completion(.failure("This URL is from a DRM-protected service (Spotify, Apple Music). Encrypted streams cannot be downloaded as audio files."))
            return
        }

        isDownloading = true
        isCancelled = false
        completionHandler = completion

        let dest = recordingsDirectory()

        if isDirectAudioURL(url) {
            downloadDirect(url: url, destination: dest)
        } else {
            downloadWithYtDlp(url: url, destination: dest)
        }
    }

    func cancelDownload() {
        isCancelled = true
        downloadTask?.cancel()
        downloadTask = nil
        ytDlpProcess?.terminate()
        ytDlpProcess = nil
        isDownloading = false
        onProgress = nil
        // completionHandler left in place — delegate will still fire and deliver .cancelled
    }

    // MARK: - Destination

    private func recordingsDirectory() -> URL {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Switchboard")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - URL Classification

    private let directAudioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "flac", "ogg", "opus", "aiff", "aif", "wma", "alac"
    ]

    private func isDirectAudioURL(_ url: URL) -> Bool {
        directAudioExtensions.contains(url.pathExtension.lowercased())
    }

    private func isDrmProtected(url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let drmHosts = ["open.spotify.com", "spotify.com", "music.apple.com", "itunes.apple.com"]
        return drmHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") })
    }

    /// Strip invisible clipboard junk that can make URL(string:) fail on the first paste.
    private func sanitizeURLString(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Zero-width spaces, BOM, and other invisible Unicode often ride along from browsers.
        let invisibles = CharacterSet(charactersIn: "\u{FEFF}\u{200B}\u{200C}\u{200D}\u{2060}")
        s = s.unicodeScalars.filter { !invisibles.contains($0) }.map(String.init).joined()
        // Trailing punctuation copied from markdown or messages.
        while let last = s.last, "),.;]>'\"".contains(last) { s.removeLast() }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Direct File Download (delegate-based for progress)

    private func downloadDirect(url: URL, destination: URL) {
        let filename = outputFilename(from: url, response: nil)
        downloadDestination = destination.appendingPathComponent(filename)
        directDownloadURL = nil

        DispatchQueue.main.async { self.onProgress?(nil) }

        let task = session.downloadTask(with: url)
        downloadTask = task
        task.resume()
    }

    private func outputFilename(from url: URL, response: URLResponse?) -> String {
        if let http = response as? HTTPURLResponse,
           let cd = http.value(forHTTPHeaderField: "Content-Disposition"),
           let name = contentDispositionFilename(cd) {
            return timestampedName(name)
        }
        let name = url.lastPathComponent
        if !name.isEmpty && name != "/" {
            return timestampedName(name)
        }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "download_\(df.string(from: Date())).m4a"
    }

    private func contentDispositionFilename(_ header: String) -> String? {
        for part in header.components(separatedBy: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("filename=") {
                return trimmed.dropFirst("filename=".count)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            }
        }
        return nil
    }

    private func timestampedName(_ name: String) -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let ts = df.string(from: Date())
        if name.prefix(10).contains("-") && name.prefix(4).allSatisfy({ $0.isNumber }) {
            return name
        }
        return "download_\(ts)_\(name)"
    }

    // MARK: - yt-dlp / ffmpeg Download

    private func downloadWithYtDlp(url: URL, destination: URL) {
        guard let ytDlpPath = findExecutable("yt-dlp") else {
            deliverResult(.failure("yt-dlp is not installed.\n\nInstall with:\n  brew install yt-dlp ffmpeg\n\nThen try again."))
            return
        }

        guard let ffmpegPath = findExecutable("ffmpeg") else {
            deliverResult(.failure("ffmpeg is required by yt-dlp to extract audio, but it is not installed.\n\nInstall with:\n  brew install ffmpeg\n\nThen try again."))
            return
        }
        // GUI apps don't inherit Homebrew's PATH, so yt-dlp can't find ffmpeg on its own.
        // Pass the directory explicitly and augment the subprocess environment.
        let ffmpegDir = URL(fileURLWithPath: ffmpegPath).deletingLastPathComponent().path

        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = df.string(from: Date())
        let outputTemplate = destination.appendingPathComponent("download_\(timestamp)_%(title)s.%(ext)s").path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytDlpPath)
        process.environment = augmentedEnvironment()
        process.arguments = [
            "--ffmpeg-location", ffmpegDir,
            "--extract-audio",
            "--audio-format", "mp3",
            "--audio-quality", "320K",
            "--postprocessor-args", "ffmpeg:-b:a 320k",
            "--output", outputTemplate,
            "--no-playlist",
            url.absoluteString
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        ytDlpOutputBuffer = ""

        // Read yt-dlp stdout in real-time to parse download progress lines.
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.ytDlpOutputBuffer.append(text)
            for line in text.components(separatedBy: "\n") {
                if let progress = self?.parseYtDlpProgress(from: line) {
                    DispatchQueue.main.async { self?.onProgress?(progress) }
                }
            }
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }

            // Stop the readability handler first, then drain whatever bytes remain
            // in the pipe buffer that the handler may not have read yet.
            pipe.fileHandleForReading.readabilityHandler = nil
            let remaining = pipe.fileHandleForReading.readDataToEndOfFile()
            if let text = String(data: remaining, encoding: .utf8), !text.isEmpty {
                self.ytDlpOutputBuffer.append(text)
            }

            if self.isCancelled {
                self.deliverResult(.cancelled)
                return
            }

            if proc.terminationStatus == 0 {
                let file = self.findLatestDownload(in: destination, after: timestamp)
                self.deliverResult(.success(file ?? destination))
            } else {
                let hint = self.ytDlpErrorHint(from: self.ytDlpOutputBuffer, url: url)
                self.deliverResult(.failure(hint))
            }
        }

        do {
            try process.run()
            ytDlpProcess = process
            DispatchQueue.main.async { self.onProgress?(nil) }
        } catch {
            deliverResult(.failure("Failed to launch yt-dlp: \(error.localizedDescription)"))
        }
    }

    private func parseYtDlpProgress(from line: String) -> Double? {
        guard line.contains("[download]") else { return nil }
        // Match "45.2%" or "100%"
        guard let pctRange = line.range(of: #"\d+\.?\d*(?=%)"#, options: .regularExpression) else { return nil }
        return Double(line[pctRange]).map { min($0 / 100.0, 1.0) }
    }

    private func findLatestDownload(in directory: URL, after timestamp: String) -> URL? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else { return nil }
        return files
            .filter { $0.lastPathComponent.hasPrefix("download_\(timestamp)") }
            .sorted {
                // Prefer the final mp3 over any leftover intermediate file.
                let aIsMp3 = $0.pathExtension.lowercased() == "mp3"
                let bIsMp3 = $1.pathExtension.lowercased() == "mp3"
                if aIsMp3 != bIsMp3 { return aIsMp3 }
                let da = (try? $0.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                let db = (try? $1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                return da > db
            }
            .first
    }

    // MARK: - Tool Discovery

    private let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    /// Menu-bar apps inherit a minimal PATH. Ensure yt-dlp subprocesses can find Homebrew tools.
    private func augmentedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = searchPaths.prefix(2).joined(separator: ":")
        if let path = env["PATH"], !path.isEmpty {
            env["PATH"] = "\(extra):\(path)"
        } else {
            env["PATH"] = "\(extra):/usr/bin:/bin"
        }
        return env
    }

    private func findExecutable(_ name: String) -> String? {
        for dir in searchPaths {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = [name]
        let p = Pipe()
        which.standardOutput = p
        which.standardError = Pipe()
        try? which.run()
        which.waitUntilExit()
        let out = String(data: p.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? nil : out
    }

    // MARK: - Error Hinting

    private func ytDlpErrorHint(from output: String, url: URL) -> String {
        let lower = output.lowercased()

        // ffmpeg missing at post-processing time (common when launched from Finder, not Terminal).
        if lower.contains("ffmpeg not found") || lower.contains("ffprobe and ffmpeg not found")
            || lower.contains("ffmpeg-location") {
            return "ffmpeg was not found by yt-dlp during audio conversion.\n\nInstall or update with:\n  brew install ffmpeg\n\nThen relaunch Switchboard and try again."
        }
        // yt-dlp itself needs updating (YouTube changes its player frequently).
        if lower.contains("nsig function") || lower.contains("player function")
            || lower.contains("could not find js function")
            || lower.contains("unrecognized option") || lower.contains("unrecognized arguments") {
            return "yt-dlp needs to be updated to handle this URL.\n\nRun:\n  brew upgrade yt-dlp\n\nThen try again."
        }
        // Unsupported site.
        if lower.contains("is not a supported url") || lower.contains("unsupported url") {
            return "yt-dlp does not support this URL.\n\nSupported sources: YouTube, Vimeo, SoundCloud, Bandcamp, and many others."
        }
        // No downloadable audio stream.
        if lower.contains("requested format is not available") || lower.contains("no video formats found") {
            return "yt-dlp could not find a downloadable audio stream at this URL."
        }
        // Auth / bot-check.
        if lower.contains("sign in to confirm") || lower.contains("confirm you") {
            return "YouTube is asking for a sign-in check.\n\nTry running this URL in a browser first, then retry."
        }
        // Private or login-gated.
        if lower.contains("private video") || lower.contains("members only")
            || lower.contains("this video is unavailable") {
            return "This video is private or members-only. yt-dlp cannot access it without credentials."
        }
        // Geo-block / copyright.
        if lower.contains("not available in your country") || lower.contains("geographic")
            || lower.contains("copyright") {
            return "This content is blocked or unavailable in your region."
        }
        // HTTP-level errors — match only the exact HTTP status strings, not loose "not found".
        if lower.contains("http error 403") || lower.contains("403 forbidden") {
            return "Access denied (HTTP 403). The content may require authentication."
        }
        if lower.contains("http error 404") || lower.contains("404 not found") {
            return "Content not found (HTTP 404). Check that the URL is correct."
        }
        if lower.contains("http error 429") || lower.contains("too many requests") {
            return "YouTube rate-limited this request (HTTP 429). Wait a few minutes and try again."
        }

        // Fall through — show the raw yt-dlp output so the error is always diagnosable.
        let excerpt = output.isEmpty ? "No details available." : String(output.suffix(500))
        return "yt-dlp encountered an error:\n\n\(excerpt)"
    }

    // MARK: - State

    /// Capture and clear the completion handler before calling it so it's always called exactly once.
    private func deliverResult(_ result: DownloadResult) {
        let handler = completionHandler
        isDownloading = false
        downloadTask = nil
        ytDlpProcess = nil
        completionHandler = nil
        downloadDestination = nil
        directDownloadURL = nil
        ytDlpOutputBuffer = ""
        DispatchQueue.main.async { handler?(result) }
    }
}

// MARK: - URLSessionDownloadDelegate

extension AudioDownloader: URLSessionDownloadDelegate {

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let progress: Double? = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : nil
        DispatchQueue.main.async { self.onProgress?(progress) }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard !isCancelled, let dest = downloadDestination else { return }
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: location, to: dest)
            directDownloadURL = dest
        } catch {
            directDownloadURL = nil
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if isCancelled {
            deliverResult(.cancelled)
            return
        }
        if let error {
            deliverResult(.failure(error.localizedDescription))
            return
        }
        if let url = directDownloadURL {
            deliverResult(.success(url))
        } else {
            deliverResult(.failure("Download failed: could not save the file."))
        }
    }
}
