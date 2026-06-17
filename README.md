# Switchboard

Switchboard is a lightweight macOS menu bar utility for power-user workflows.

**v2.1.0**

## Features

### Window Switcher

- Option-Tab switcher with adaptive live thumbnails
- Mouse and keyboard selection for switching windows
- Per-window activation for apps with multiple windows
- Hide Apps submenu to exclude apps from the switcher (persisted across launches)

### Audio

- System audio recorder — saves recordings to `~/Downloads/Switchboard Recordings`
- **Audio URL downloader** — download audio straight from a URL into the same recordings folder
  - **YouTube, Vimeo, SoundCloud, Bandcamp**, and many other media pages via [yt-dlp](https://github.com/yt-dlp/yt-dlp) + ffmpeg
  - Direct audio file links (`.mp3`, `.m4a`, `.wav`, etc.) via built-in download — no extra tools required
  - **Download from Clipboard** (`⌘D`) — detects a copied `http`/`https` link and shows the host in the menu
  - **Enter URL…** (`⌘⇧D`) — paste or type a link in a dialog with working ⌘V/C/A/X/Z shortcuts
  - Live progress in the menu bar and menu while downloading, with cancel support
  - Clear errors for DRM-protected sources (Spotify, Apple Music) and common yt-dlp failures

### Menu Bar UI

- Organized **WINDOW SWITCHER** and **AUDIO** sections
- Status bar shows recording duration (`⏺ 00:42`) or download progress (`⬇︎ 73%`) while active
- **Open Recordings Folder** shortcut to jump to `~/Downloads/Switchboard Recordings`

## Requirements

- macOS 14.2 or newer
- Swift toolchain / Xcode Command Line Tools
- Accessibility permission for Option-Tab and window activation
- Screen Recording permission for live window thumbnails and system audio capture

Switchboard still opens without Screen Recording permission, but thumbnails may fall back to app icons until permission is granted.

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

On first launch, grant Accessibility in System Settings so Switchboard can listen for Option-Tab and activate windows.

Screen Recording is used for thumbnails and system audio capture. macOS may require relaunching Switchboard after granting or resetting this permission.

If Screen Recording gets stuck during development:

```sh
tccutil reset ScreenCapture com.ausarmundra.switchboard
```

## Project Layout

- `main.swift` — menu bar UI, app lifecycle, download dialogs, and menu actions
- `AltTabManager.swift` — Option-Tab switcher, window discovery, thumbnail layout, permissions, and activation
- `AudioRecorder.swift` — ScreenCaptureKit system audio recorder
- `AudioDownloader.swift` — URL audio downloader (direct files via URLSession, media pages via yt-dlp)
- `Info.plist` — app bundle metadata and permissions descriptions
- `Resources/` — app bundle assets
- `build.sh` — local build/install/sign helper

## Roadmap Ideas

- Split switcher/audio features into smaller modules
- Add more menu bar utility tools
- Package with a first-class Xcode project or Swift Package layout
