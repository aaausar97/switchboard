# Switchboard

Switchboard is a lightweight macOS menu bar utility for power-user workflows.

**v2.2.0**

## Features

### Window Switcher

- Option-Tab switcher with adaptive live thumbnails
- Mouse and keyboard selection for switching windows
- Per-window activation for apps with multiple windows
- Hide Apps submenu to exclude apps from the switcher (persisted across launches)

### Dictation (Handy-style)

- **Hold ⌥ + Space** anywhere to dictate — works like [Handy](https://handy.computer) / Whisper push-to-talk
- Offline speech-to-text via [whisper.cpp](https://github.com/ggerganov/whisper.cpp) (`whisper-small` model)
- Bottom-screen overlay shows **Listening…** and **Transcribing…** states
- Transcribed text is pasted into the focused app automatically (⌘V)
- Releasing ⌥ while holding Space also ends the recording
- Setup hints appear in the menu only when whisper-cli or the model is missing

### Audio

- System audio recorder — saves recordings to `~/Downloads/Switchboard`
- **Audio URL downloader** — download audio straight from a URL into the same folder
  - **YouTube, Vimeo, SoundCloud, Bandcamp**, and many other media pages via [yt-dlp](https://github.com/yt-dlp/yt-dlp) + ffmpeg
  - Direct audio file links (`.mp3`, `.m4a`, `.wav`, etc.) via built-in download — no extra tools required
  - **Download from Clipboard** (`⌘D`) — detects a copied `http`/`https` link and shows the host in the menu
  - **Enter URL…** (`⌘⇧D`) — paste or type a link in a dialog with working ⌘V/C/A/X/Z shortcuts
  - Live progress in the menu bar and menu while downloading, with cancel support
  - Clear errors for DRM-protected sources (Spotify, Apple Music) and common yt-dlp failures

### Menu Bar UI

- Organized **WINDOW SWITCHER**, **DICTATION**, and **AUDIO** sections
- Status bar shows recording duration (`⏺ 00:42`) or download progress (`⬇︎ 73%`) while active
- **Open Switchboard Folder** shortcut to jump to `~/Downloads/Switchboard`

## Requirements

- macOS 14.2 or newer
- Swift toolchain / Xcode Command Line Tools
- Accessibility permission for Option-Tab, Option-Space dictation, and window activation
- Screen Recording permission for live window thumbnails and system audio capture
- Microphone permission for dictation

Switchboard still opens without Screen Recording permission, but thumbnails may fall back to app icons until permission is granted.

### Optional: Offline Dictation

Install whisper.cpp and download the small English model:

```sh
brew install whisper-cpp
mkdir -p ~/.whisper/models
curl -L -o ~/.whisper/models/ggml-small.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin
```

Switchboard looks for `whisper-cli` in `/opt/homebrew/bin`, `/usr/local/bin`, or `/usr/bin`, and the model at `~/.whisper/models/ggml-small.bin`.

### Optional: Audio URL Downloads (YouTube & media pages)

To download from YouTube, SoundCloud, and other media pages, install yt-dlp and ffmpeg:

```sh
brew install yt-dlp ffmpeg
```

Direct audio file URLs work without any additional tools.

Spotify and Apple Music catalog URLs use DRM-protected streams and cannot be downloaded as audio files. Switchboard will show a clear error for those sources.

If YouTube downloads start failing after a platform change, update yt-dlp:

```sh
brew upgrade yt-dlp
```

## Build

```sh
./build.sh
```

Build, install, sign, and launch:

```sh
./build.sh --launch
```

By default, the script installs to:

```sh
/Applications/Switchboard.app
```

To install somewhere else:

```sh
APP_PATH="$HOME/Applications/Switchboard.app" ./build.sh
```

## Permissions

On first launch, grant **Accessibility** in System Settings so Switchboard can listen for ⌥⇥, ⌥ + Space dictation, and activate windows.

**Screen Recording** is used for thumbnails and system audio capture. macOS may require relaunching Switchboard after granting or resetting this permission.

**Microphone** is used only for offline dictation while you hold ⌥ + Space.

If Screen Recording gets stuck during development:

```sh
tccutil reset ScreenCapture com.ausarmundra.switchboard
```

## Project Layout

- `main.swift` — menu bar UI, app lifecycle, download dialogs, and menu actions
- `AltTabManager.swift` — Option-Tab switcher, global hotkeys (including ⌥ + Space), window discovery, thumbnail layout, permissions, and activation
- `DictationManager.swift` — offline whisper.cpp dictation, overlay UI, and auto-paste
- `AudioRecorder.swift` — ScreenCaptureKit system audio recorder
- `AudioDownloader.swift` — URL audio downloader (direct files via URLSession, media pages via yt-dlp)
- `Info.plist` — app bundle metadata and permissions descriptions
- `Resources/` — app bundle assets
- `build.sh` — local build/install/sign helper

## Roadmap Ideas

- Additional dictation engines (e.g. parakeet, moonshine)
- Split switcher/audio/dictation into smaller modules
- Add more menu bar utility tools
- Package with a first-class Xcode project or Swift Package layout
