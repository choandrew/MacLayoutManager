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
            let name = try LayoutName(name)
            guard let layout = library.layout(named: name) else {
                throw LibraryError.unknownLayout(name)
            }
            try restore(layout, on: displays)
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
        captureScreens(of: try AccessibilityWindows.scan { _ in true }.movable, on: displays)
    }

    /// Names the apps a restore couldn't open, whose windows stay unplaced.
    private struct UnopenedApps: LocalizedError {
        let bundleIDs: Set<String>

        var errorDescription: String? {
            "Couldn't open \(bundleIDs.sorted().joined(separator: ", "))."
        }
    }

    /// Moves the layout's open windows first, then opens its apps that own no standard window and
    /// places their windows as they appear.
    private static func restore(_ layout: Layout, on displays: DisplayArrangement) throws {
        let bundleIDs = Set(layout.screens.flatMap { $0.windows.map(\.bundleID) })
        let windowless = bundleIDs.subtracting(
            try place(layout, appsIn: bundleIDs, on: displays).owners)

        let unopened = openApps(windowless)
        var opening = OpeningApps(windowless.subtracting(unopened), at: .now)
        while !opening.bundleIDs.isEmpty {
            Thread.sleep(forTimeInterval: OpeningApps.pollInterval / .seconds(1))
            let scan = try place(layout, appsIn: opening.bundleIDs, on: displays)
            opening.observe(scan.movable.map(\.bundleID), at: .now)
        }
        if !unopened.isEmpty {
            throw UnopenedApps(bundleIDs: unopened)
        }
    }

    private static func place(
        _ layout: Layout, appsIn bundleIDs: Set<String>, on displays: DisplayArrangement
    ) throws -> AccessibilityWindows.Scan {
        let scan = try AccessibilityWindows.scan { bundleIDs.contains($0) }
        AccessibilityWindows.apply(
            restorePlan(for: layout, windows: scan.movable, displays: displays))
        return scan
    }

    /// Opens each app without bringing it forward: `open` launches an app that isn't running and
    /// asks a running one to reopen a window. Returns the apps it couldn't open, such as uninstalled
    /// ones.
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
