# Renamer for Raycast

Search for a named macOS desktop in Raycast and press Return to switch to it. This extension needs Renamer 0.1.1 or newer installed and running on the same Mac.

## Local setup

1. Build Renamer from the project root with `zsh app/build.sh` and install the resulting `dist/Renamer.app` in `/Applications`. Launch Renamer and grant Accessibility permission if prompted.
2. From this `raycast` directory, run `npm install` and `npm run dev`. Raycast's **Search Desktops** command will appear in the Development section. You can stop the development server after the command has been imported.
3. If Renamer is installed somewhere else, set **Renamer App Path** in the extension preferences to the full path of `Renamer.app`.

The command asks Renamer for a fresh list of ordinary desktops, then sends the selected desktop identity back to Renamer. Renamer verifies that the desktop still exists before switching. The **Enable desktop search** switch controls Renamer's built-in search and shortcut; this Raycast command remains available independently. Names stay on this Mac; the extension makes no network requests.

## Checks

Run `npm run build` and `npm run lint` from this directory. The app's Swift build must also succeed. For a manual check, search for a desktop, switch to it, rename it in Renamer, then reopen the Raycast command and confirm the new name appears. Turn off Renamer's built-in desktop search and confirm the Raycast command still works.
