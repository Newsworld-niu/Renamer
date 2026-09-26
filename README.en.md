# Renamer

[简体中文](README.md) | English

Renamer is a macOS Spaces naming utility. It displays custom names on desktop thumbnails in Mission Control and lets you search for and switch to a desktop by name. The current public version is a **0.1.1 preview**.

## Download and install

1. Download `Renamer-v0.1.1-arm64.dmg` from [Releases](https://github.com/Newsworld-niu/Renamer/releases). GitHub's automatic “Source code” archives contain source files, not the app.
2. Double-click the DMG, drag `Renamer.app` to Applications, eject the disk image, and open Renamer from Applications.
3. This preview has not been notarized by Apple. If macOS blocks the first launch, try opening the app once, then select **Open Anyway** in **System Settings → Privacy & Security**. You do not need to disable macOS security protections.
4. Grant Accessibility access when prompted so Renamer can show names in Mission Control and switch desktops.

The download is for Apple silicon Macs. You do not need Xcode or the build commands below to use it.

## Features

- Name regular desktops on each display and show their names in Mission Control.
- View, switch to, and rename desktops from the menu bar.
- Enable or disable desktop search, and set a global shortcut when search is enabled.
- Adjust the thumbnail labels' colors, position, and font size; optionally show the current desktop's name separately.
- Save names and preferences locally, with an optional launch at login setting.

## Requirements

Apple silicon and macOS 14 or later. The app has only been tested on macOS 26.3. Renamer uses undocumented macOS Spaces interfaces, so a system update may require changes to the app.

## Build from source

Install the Xcode Command Line Tools. From the project root, run:

```sh
zsh app/setup-signing.sh
zsh app/build.sh
open dist/Renamer.app
```

Run `setup-signing.sh` once to create a local development signing identity in your login Keychain. Later builds reuse it. The private key stays in your Keychain and is not part of this repository. The build produces `dist/Renamer.app`. On first use, grant Renamer Accessibility access in System Settings when prompted. This local development signature is not an Apple notarized public release.

## Usage

Enter names for your desktops in the main window. The names appear on desktop thumbnails in Mission Control. Use the menu bar icon to switch desktops, rename them, or open settings.

The **Enable desktop search** switch controls search. Turning it off disables the search entry points and global shortcut. Turning it back on restores the previously saved shortcut. Search is enabled by default on a new installation, and you can change its shortcut in the main window.

Desktop names are stored in `~/Library/Application Support/Renamer/names.json` and are not uploaded automatically. Some desktops do not expose a persistent UUID. After a system restart, Renamer restores a name for such a desktop only when the identities of its neighboring desktops uniquely confirm the match. Otherwise, it keeps the old record to avoid assigning the name to the wrong desktop.

## Raycast desktop search

The [Raycast extension](raycast/README.md) adds a separate **Search Desktops** command to find and switch to a desktop by name. It is [under review for the Raycast Store](https://github.com/raycast/extensions/pull/31588). Once approved and published, search for **Renamer Desktop Search** in Raycast to install it. Install Renamer 0.1.1 or newer first. The Raycast command remains available when Renamer's built-in **Enable desktop search** setting is off.

## Issues and contributing

If you find a bug or have a feature idea, please open an [Issue](https://github.com/Newsworld-niu/Renamer/issues). Include the Renamer and macOS versions, your Mac model, steps to reproduce, and what you expected versus what happened. Screenshots or diagnostics can help. Before sharing logs or `names.json`, check them for personal information such as your desktop names.

Code, documentation, and translation contributions are welcome through [Pull Requests](https://github.com/Newsworld-niu/Renamer/pulls). For larger changes, consider opening an Issue first. In your PR, explain why you made the change and how you checked it, and keep each PR focused on one topic.
