# Switchboard

Switchboard is a lightweight macOS menu bar utility for power-user workflows.

Current features:

- Option-Tab window switcher with adaptive live thumbnails
- Mouse and keyboard selection for switching windows
- Per-window activation for apps with multiple windows
- App exclusion menu for the switcher
- System audio recorder that saves recordings to `~/Downloads/Switchboard Recordings`

## Requirements

- macOS 14.2 or newer
- Swift toolchain / Xcode Command Line Tools
- Accessibility permission for Option-Tab and window activation
- Screen Recording permission for live window thumbnails

Switchboard still opens without Screen Recording permission, but thumbnails may fall back to app icons until permission is granted.

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

- `main.swift` - menu bar UI, app lifecycle, and menu actions
- `AltTabManager.swift` - Option-Tab switcher, window discovery, thumbnail layout, permissions, and activation
- `AudioRecorder.swift` - ScreenCaptureKit system audio recorder
- `Info.plist` - app bundle metadata and permissions descriptions
- `Resources/` - app bundle assets
- `build.sh` - local build/install/sign helper

## Roadmap Ideas

- Persist settings and app exclusions
- Split switcher/audio features into smaller modules
- Add more menu bar utility tools
- Package with a first-class Xcode project or Swift Package layout
