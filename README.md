# MacLayoutManager

A menu bar app that saves named window layouts across multiple displays and restores them on demand
or when your displays change.

## Features

- **Named layouts.** *Save Current Layout…* records every standard window that isn't minimized or
  full screen, grouped by the display it sits on. Saving under an existing name overwrites that
  layout. Click a layout to restore it, or hover it for *Restore*, *Overwrite with Current
  Layout*, *Auto-Restore on These Displays*, *Rename…*, and *Delete…*.
- **Multi-monitor.** Displays are identified by their CoreGraphics UUID. Window frames are stored as
  fractions of the display's visible area, so a layout rescales to a different resolution. Windows
  saved on a display that is no longer connected land on the main display.
- **Auto-restore on display change.** A layout with *Auto-Restore on These Displays* checked restores
  2 seconds after a display reconfiguration (connect, disconnect, resolution change, wake) that
  leaves exactly the displays it was saved with. Each display set has at most one auto-restore
  layout: a newly saved layout starts checked and takes over from any older layout on the same
  displays.
- **Launch at Login**, on by default after the first launch, with the opt-out remembered.

Restore matches saved windows to open windows of the same app by exact title first, then
front-to-back order, and skips minimized and full-screen windows. It moves the open windows first,
then launches each app in the layout that isn't running, without bringing it forward. A running app
is left alone even with no window open, since its windows may be on another Space. Restore places a
launched app's windows as they appear, until the app has shown a window and its window count has
held for 2 seconds, 15 seconds pass, or the displays change. Auto-restore launches apps the same way.

## Install

Requires macOS 15 or newer and Apple silicon.

```sh
curl -fsSL https://github.com/choandrew/MacLayoutManager/releases/latest/download/setup.sh | bash
```

The script downloads the latest release, creates the `MacLayoutManager Dev` signing identity in the
login keychain if it is missing, signs the app with it, replaces any copy in `/Applications`, and
launches the app. It uses only tools that ship with macOS. Then grant **System Settings → Privacy &
Security → Accessibility**. The stable signing identity keeps that grant across updates; set
`CODESIGN_IDENTITY` to sign with a different identity.

## Design

The process that stays running is a 90 KB Objective-C executable: one status item with a drawn
icon, the layout names in fixed-size C records, and a display reconfiguration callback. It builds
the menu only while it is open, runs no periodic timers, and reads the login item's status off the
main thread, so opening the menu never waits on ServiceManagement. Measured on macOS
26.6 before the menu first opens, it settles at 12.8-13.0 MB, below an otherwise empty status-item
app using an SF Symbol icon (13.0-13.6 MB).

Every command runs in `Contents/Helpers/MacLayoutHelper`, a 200 KB Swift executable that loads the
layouts file, captures or moves windows through the Accessibility API, writes the file, prints a
tab-separated summary, and exits. A `list` run peaks at 1.8 MB. Each app answers Accessibility calls
one at a time on its main thread, so the helper gives every app its own worker and runs up to one
worker per CPU core: while the apps fit the cores, a capture or restore lasts about as long as its
slowest app rather than all apps together. An app that leaves a call unanswered for its full
1-second timeout gets no further calls in that pass. `app/HelperProtocol.h` specifies its arguments and output, and
the Swift helper imports that header, so both sides share one set of limits and verbs. The host
serializes helper runs, and the helper holds a lock around each load-change-save cycle, so a command
chosen while a restore waits for opened apps' windows runs after that restore.

Layouts live in `~/Library/Application Support/MacLayoutManager/layouts.json`. The helper validates
the file on every run (unique names, at most 64 layouts, one auto-restore layout per display set)
and never writes a file it could not read.

## Build

Building needs the Xcode command line tools.

```sh
./setup.sh --build  # build this checkout, then sign and install it
app/build.sh        # build app/build/MacLayoutManager.app and .zip without installing
```

The build runs the Swift model tests and the protocol parser tests, compiles size-optimized arm64
binaries with link-time optimization into an unsigned bundle, and zips it.

## Release

CI runs `setup.sh --build` with ad-hoc signing on pull requests and pushes to `main`. Pushing a tag
`v<version>` that matches `CFBundleShortVersionString` in `app/Info.plist` publishes the unsigned
`MacLayoutManager.zip` and the `setup.sh` that installs it as a GitHub release.
