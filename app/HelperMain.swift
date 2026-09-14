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
        captureScreens(of: try AccessibilityWindows.windows { _ in true }, on: displays)
    }

    private static func restore(_ layout: Layout, on displays: DisplayArrangement) throws {
        let bundleIDs = Set(layout.screens.flatMap { $0.windows.map(\.bundleID) })
        let windows = try AccessibilityWindows.windows { bundleIDs.contains($0) }
        AccessibilityWindows.apply(restorePlan(for: layout, windows: windows, displays: displays))
    }
}
