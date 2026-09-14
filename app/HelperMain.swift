import CoreGraphics
import Foundation

/// Runs one command against the saved layouts, writes the output HelperProtocol.h specifies, and
/// exits, so the resident host never loads Swift, JSON, or Accessibility clients.
@main
enum HelperMain {
    static func main() {
        guard let command = Command(arguments: CommandLine.arguments.dropFirst()) else { exit(2) }
        let url = URL.applicationSupportDirectory.appending(path: "MacLayoutManager/layouts.json")

        let outcome: Outcome
        do {
            try lockLayouts(at: url)
            let library = try LayoutFile.load(from: url)
            do {
                outcome = .loaded(try perform(command, on: library, savingTo: url), failure: nil)
            } catch {
                outcome = .loaded(library, failure: error)
            }
        } catch {
            outcome = .unloaded(UnreadableLayouts(path: url.path, underlying: error))
        }
        FileHandle.standardOutput.write(Data(outcome.output.utf8))
    }

    /// Names the file, so a user told the app can't start knows what to fix.
    private struct UnreadableLayouts: LocalizedError {
        let path: String
        let underlying: any Error

        var errorDescription: String? { "\(path): \(underlying.localizedDescription)" }
    }

    /// Holds an exclusive lock beside the layouts file until the process exits, so two helpers (from
    /// two copies of the app, say) can't interleave load and save and lose an update.
    private static func lockLayouts(at url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(
            directory.appending(path: ".lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0, flock(descriptor, LOCK_EX) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// The library after `command`, saved when it changed.
    private static func perform(_ command: Command, on library: LayoutLibrary, savingTo url: URL)
        throws
        -> LayoutLibrary
    {
        var updated = library
        switch command {
        case .list:
            break
        case .add(let name, let displays):
            let name = try LayoutName(name)
            try updated.add(name, screens: capture(on: displays))
        case .replace(let name, let displays):
            let name = try LayoutName(name)
            try updated.replaceScreens(of: name, with: capture(on: displays))
        case .restore(let name, let displays):
            try restore(library.layout(named: LayoutName(name)), on: displays)
        case .autoRestore(let displays):
            if let layout = library.autoRestoreLayout(for: displays.ids) {
                try restore(layout, on: displays)
            }
        case .rename(let name, let newName):
            try updated.rename(LayoutName(name), to: LayoutName(newName))
        case .setAutoRestore(let name, let enabled):
            try updated.setAutoRestore(LayoutName(name), enabled)
        case .delete(let name):
            try updated.delete(LayoutName(name))
        }
        if updated != library {
            try LayoutFile.save(updated, to: url)
        }
        return updated
    }

    private static func capture(on displays: DisplayArrangement) throws -> [ScreenLayout] {
        let everyApp = { (_: String) in true }
        let windows = try AccessibilityWindows.forEachApp(where: everyApp) { app in
            app.movable.map {
                LiveWindow(handle: (), bundleID: $0.bundleID, title: $0.title, frame: $0.frame)
            }
        }
        return captureScreens(of: windows.flatMap { $0 }, on: displays)
    }

    /// Names the apps a restore couldn't open, whose windows stay unplaced.
    private struct UnopenedApps: LocalizedError {
        let bundleIDs: Set<String>

        var errorDescription: String? {
            "Couldn't open \(bundleIDs.sorted().joined(separator: ", "))."
        }
    }

    /// Moves the layout's open windows first, then launches its apps that aren't running and places
    /// their windows as they appear, until they settle or the displays change. A display change makes
    /// `displays` stale and starts the host's own auto-restore.
    ///
    /// A running app is never asked to reopen a window: Accessibility lists only the current Space's
    /// windows, so an app whose windows sit on another Space or in full screen looks windowless and
    /// would open a stray one.
    private static func restore(_ layout: Layout, on displays: DisplayArrangement) throws {
        let activeDisplays = ActiveDisplay.all()
        let bundleIDs = Set(layout.screens.flatMap { $0.windows.map(\.bundleID) })
        // Every app owning a normal-layer window is running and gets a count.
        let windowless = bundleIDs.subtracting(
            try place(layout, appsIn: bundleIDs, on: displays).keys)
        let notRunning = windowless.subtracting(AccessibilityWindows.runningApps(among: windowless))

        let unopened = openApps(notRunning)
        var opening = OpeningApps(notRunning.subtracting(unopened), at: .now)
        while !opening.bundleIDs.isEmpty {
            Thread.sleep(forTimeInterval: OpeningApps.pollInterval / .seconds(1))
            guard ActiveDisplay.all() == activeDisplays else { break }
            opening.observe(try place(layout, appsIn: opening.bundleIDs, on: displays), at: .now)
        }
        if !unopened.isEmpty {
            throw UnopenedApps(bundleIDs: unopened)
        }
    }

    /// Moves the windows of the layout's apps in `bundleIDs` into place, each app on its own worker,
    /// and returns the standard window count of each app that owns a normal-layer window.
    private static func place(
        _ layout: Layout, appsIn bundleIDs: Set<String>, on displays: DisplayArrangement
    ) throws -> [String: Int] {
        let counts = try AccessibilityWindows.forEachApp(where: bundleIDs.contains) { app in
            app.apply(restorePlan(for: layout, windows: app.movable, displays: displays))
            return (app.bundleID, app.windowCount)
        }
        return Dictionary(uniqueKeysWithValues: counts)
    }

    private struct ActiveDisplay: Equatable {
        let id: CGDirectDisplayID
        let bounds: CGRect

        /// Every display reconfiguration changes this list: connecting, disconnecting, arranging,
        /// or resizing a display.
        static func all() -> [ActiveDisplay] {
            var count: UInt32 = 0
            guard CGGetActiveDisplayList(0, nil, &count) == .success else { return [] }
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
            guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
            return ids.prefix(Int(count)).map { ActiveDisplay(id: $0, bounds: CGDisplayBounds($0)) }
        }
    }

    /// Launches each app without bringing it forward. Returns the apps `open` couldn't launch, such as
    /// uninstalled ones.
    private static func openApps(_ bundleIDs: Set<String>) -> Set<String> {
        let launches = bundleIDs.map { bundleID -> (String, Process?) in
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/open")
            process.arguments = ["-g", "-b", bundleID]
            // The helper's standard output carries the protocol.
            process.standardOutput = FileHandle.nullDevice
            do {
                try process.run()
                return (bundleID, process)
            } catch {
                return (bundleID, nil)
            }
        }
        return Set(
            launches.compactMap { bundleID, process in
                process?.waitUntilExit()
                return process?.terminationStatus == 0 ? nil : bundleID
            })
    }
}
