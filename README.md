# MacLayoutManager

A menu bar app that saves named window layouts across multiple displays and restores them on demand or when your displays change.

## Features

- **Named layouts.** *Save Current Layout…* records every standard window of every regular app, grouped by the display it sits on. Saving under an existing name replaces that layout.
- **Multi-monitor.** Displays are identified by their CoreGraphics UUID. Window frames are stored as fractions of the display's visible area, so a layout rescales to a different resolution. Windows saved on a display that is no longer connected land on the main display.
- **Auto-restore on display change.** *Manage Layouts → (layout) → Auto-Restore on These Displays* restores that layout 2 seconds after any display reconfiguration (connect, disconnect, resolution change, wake) that leaves exactly the displays it was saved with. Each display set has at most one auto-restore layout.
- **Launch at Login** toggle, so auto-restore keeps working after a reboot.

Restore matches saved windows to open windows of the same app by exact title first, then front-to-back order. It only moves windows that are already open: it doesn't launch apps, and it skips minimized and full-screen windows.

## Build

Requires macOS 15 and the Swift 6 toolchain (Xcode or Command Line Tools).

```sh
./scripts/build-app.sh          # produces build/MacLayoutManager.app
cp -R build/MacLayoutManager.app /Applications/
open /Applications/MacLayoutManager.app
swift test                      # layout matching, scaling, and library validation
```

## Permissions

Reading and moving other apps' windows requires **System Settings → Privacy & Security → Accessibility**. The app is ad-hoc signed, so macOS ties the grant to the exact binary: after each rebuild, remove MacLayoutManager from the Accessibility list and add it again.

## Data

Layouts live in `~/Library/Application Support/MacLayoutManager/layouts.json`. The app validates the file at launch (unique names, one auto-restore layout per display set) and refuses to start rather than overwrite a file it can't read.
