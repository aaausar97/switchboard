# Switchboard

Switchboard is a lightweight macOS menu bar utility for power-user workflows.

**v2.2.0**

## Features

### Window Switcher

- **⌥⇥** — Windows-style Option-Tab switcher with adaptive live thumbnails
- Mouse and keyboard selection for switching windows
- Per-window activation for apps with multiple windows
- **Hide Apps from Option-Tab** submenu to exclude apps (persisted across launches)

### Dictation

Handy-style offline push-to-talk dictation powered by [whisper.cpp](https://github.com/ggerganov/whisper.cpp).

- **Hold ⌥ + Space** anywhere to dictate
- Uses the `whisper-small` model (`ggml-small.bin`) — fully offline, no cloud
- Compact bottom-center **notification pill** while active:
  - **Listening** — red dot + microphone icon
  - **Transcribing** — yellow dot + text icon
  - **Errors** — short text message (missing setup, permissions, failures) that auto-dismisses
- Transcribed text is pasted into the focused app automatically (⌘V)
- Releasing ⌥ while still holding Space also ends the recording
- Menu shows setup hints only when `whisper-cli` or the model is missing

### Audio

- **Record System Audio** (`⌘R`) — ScreenCaptureKit capture saved to `~/Downloads/Switchboard` as `.m4a`
- **Audio URL downloader** — save audio from a URL into the same folder
  - Media pages (**YouTube**, Vimeo, SoundCloud, Bandcamp, etc.) via [yt-dlp](https://github.com/yt-dlp/yt-dlp) + ffmpeg
  - Direct file links (`.mp3`, `.m4a`, `.wav`, etc.) — no extra tools required
  - **Download from Clipboard** (`⌘D`) — detects a copied URL and shows the host in the menu
  - **Enter URL…** (`⌘⇧D`) — paste or type a link in a dialog with working ⌘V/C/A/X/Z shortcuts
  - Live progress in the menu bar and menu, with cancel support
  - Clear errors for DRM-protected sources (Spotify, Apple Music) and common yt-dlp failures
- **Open Switchboard Folder** — opens `~/Downloads/Switchboard` in Finder

### Menu Bar

- Sections: **WINDOW SWITCHER**, **DICTATION**, **AUDIO**
- Status icon shows recording duration (`⏺ 00:42`) or download progress (`⬇︎ 73%`) while active

## Requirements

- macOS 14.2+
- Swift toolchain / Xcode Command Line Tools
- **Accessibility** — Option-Tab, ⌥ + Space dictation, and window activation
- **Screen Recording** — live window thumbnails and system audio capture
- **Microphone** — offline dictation only (while holding ⌥ + Space)

Switchboard opens without Screen Recording permission, but thumbnails fall back to app icons until it is granted.

## Optional Setup

### Offline Dictation

```sh
brew install whisper-cpp
mkdir -p ~/.whisper/models
curl -L -o ~/.whisper/models/ggml-small.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin
```

Switchboard looks for `whisper-cli` in `/opt/homebrew/bin`, `/usr/local/bin`, or `/usr/bin`, and the model at `~/.whisper/models/ggml-small.bin`.

### Audio URL Downloads

```sh
brew install yt-dlp ffmpeg
```

Direct audio file URLs work without additional tools. Spotify and Apple Music catalog URLs are DRM-protected and cannot be downloaded — Switchboard shows a clear error.

If YouTube downloads break after a platform change:

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

Default install path: `/Applications/Switchboard.app`

Custom path:

```sh
APP_PATH="$HOME/Applications/Switchboard.app" ./build.sh
```

## Permissions

Grant permissions in **System Settings** on first launch:

| Permission | Used for |
|---|---|
| Accessibility | ⌥⇥ switcher, ⌥ + Space dictation, window activation |
| Screen Recording | Window thumbnails, system audio recording |
| Microphone | Voice capture during dictation |

macOS may require relaunching Switchboard after granting Screen Recording.

Reset Screen Recording during development:

```sh
tccutil reset ScreenCapture com.ausarmundra.switchboard
```

## Project Layout

| File | Role |
|---|---|
| `main.swift` | Menu bar UI, app lifecycle, download dialogs |
| `AltTabManager.swift` | Option-Tab switcher, global hotkeys, thumbnails, window activation |
| `DictationManager.swift` | Offline whisper dictation, notification pill, auto-paste |
| `AudioRecorder.swift` | ScreenCaptureKit system audio recorder |
| `AudioDownloader.swift` | URL audio downloader (URLSession + yt-dlp) |
| `Info.plist` | Bundle metadata and permission descriptions |
| `Resources/` | App bundle assets |
| `build.sh` | Build, install, and sign helper |

## Roadmap

- Additional dictation engines (parakeet, moonshine)
- Split into smaller modules
- More menu bar utilities
- First-class Xcode project or Swift Package layout
