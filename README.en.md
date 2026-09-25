# Renamer

[简体中文](README.md) | English

Renamer is a macOS Spaces naming utility. It displays custom names on desktop thumbnails in Mission Control and lets you search for and switch to a desktop by name. The current version is a **0.9.12 technical preview**.

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

## Development

Application source is in `app/Sources/`, and model checks are in `app/Tests/`. `dist/` contains local build output and is excluded from Git. See `app/THIRD_PARTY_NOTICES.txt` for third party technique references.
