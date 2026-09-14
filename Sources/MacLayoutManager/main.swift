import AppKit
import LayoutCore

let libraryURL = URL.applicationSupportDirectory.appending(path: "MacLayoutManager/layouts.json")
let app = NSApplication.shared
do {
    let delegate = AppDelegate(library: try LayoutFile.load(from: libraryURL), libraryURL: libraryURL)
    app.delegate = delegate
    // NSApplication holds its delegate weakly.
    withExtendedLifetime(delegate) { app.run() }
} catch {
    let alert = NSAlert()
    alert.messageText = "Couldn't load layouts from \(libraryURL.path)"
    alert.informativeText = error.localizedDescription
    alert.runModal()
    exit(1)
}
