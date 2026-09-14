import CoreGraphics
import Foundation

/// Drives the helper's layout model, window matching, argv parsing, and output. The output fixture
/// file is also parsed by tests/ProtocolTests.m, which holds the host to the same text.
@main
struct LayoutCoreTests {
    static let laptop = LiveDisplay(
        id: DisplayID(rawValue: "laptop"), name: "Built-in Retina Display",
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 33, width: 1512, height: 949))
    static let monitor = LiveDisplay(
        id: DisplayID(rawValue: "monitor"), name: "DELL U2720Q",
        frame: CGRect(x: 1512, y: -500, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1512, y: -475, width: 2560, height: 1415))

    var checks = 0
    var failures = 0

    static func main() {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(
                Data("usage: LayoutCoreTests <protocol-output.txt>\n".utf8))
            exit(2)
        }
        var tests = LayoutCoreTests()
        do {
            try tests.captureThenRestoreReproducesFrames()
            try tests.restoreMatchesTitlesBeforeOrder()
            try tests.restoreScalesWindowsFromMissingDisplayOntoMain()
            try tests.openingAppsLeaveOnceTheirWindowsSettle()
            try tests.identicalMonitorsGetDistinctIDsLeftToRight()
            try tests.replacingScreensKeepsAutoRestoreAndTakesItOver()
            try tests.autoRestoreIsExclusivePerDisplaySet()
            try tests.namesAreValidatedAndUnique()
            try tests.fileRoundTripsAndLoadRejectsConflicts()
            try tests.argumentsParseStrictly()
            try tests.outputMatchesProtocolFixture(path: CommandLine.arguments[1])
        } catch {
            tests.expect(false, "unexpected error: \(error)")
        }
        guard tests.failures == 0 else {
            FileHandle.standardError.write(
                Data("LayoutCoreTests: \(tests.failures) of \(tests.checks) checks failed\n".utf8))
            exit(1)
        }
        print("LayoutCoreTests: \(tests.checks) checks passed")
    }

    mutating func expect(_ condition: Bool, _ label: String, line: UInt = #line) {
        checks += 1
        guard !condition else { return }
        failures += 1
        FileHandle.standardError.write(Data("LayoutCoreTests.swift:\(line): \(label)\n".utf8))
    }

    mutating func expect(_ expected: LibraryError, line: UInt = #line, _ body: () throws -> Void) {
        do {
            try body()
            expect(false, "expected \(expected), got no error", line: line)
        } catch {
            expect(
                error as? LibraryError == expected, "expected \(expected), got \(error)", line: line
            )
        }
    }

    static func window(_ handle: Int, _ bundleID: String, _ title: String, _ frame: CGRect)
        -> LiveWindow<Int>
    {
        LiveWindow(handle: handle, bundleID: bundleID, title: title, frame: frame)
    }

    static func screen(_ display: LiveDisplay, _ windows: [WindowPlacement] = []) -> ScreenLayout {
        ScreenLayout(display: display.id, displayName: display.name, windows: windows)
    }

    mutating func captureThenRestoreReproducesFrames() throws {
        let displays = DisplayArrangement(displays: [Self.laptop, Self.monitor])!
        let saved = [
            Self.window(
                1, "com.apple.Safari", "Docs", CGRect(x: 100, y: 60, width: 900, height: 700)),
            // Mostly on the monitor, so it belongs to the monitor.
            Self.window(
                2, "com.apple.Terminal", "zsh", CGRect(x: 1400, y: 100, width: 800, height: 600)),
        ]
        let screens = captureScreens(of: saved, on: displays)
        expect(
            screens.map(\.display) == [Self.laptop.id, Self.monitor.id], "screens follow displays")
        expect(
            screens.map { $0.windows.map(\.title) } == [["Docs"], ["zsh"]],
            "windows land on largest overlap")

        let layout = Layout(name: try LayoutName("Desk"), screens: screens, autoRestore: false)
        let moved = [
            Self.window(1, "com.apple.Safari", "Docs", .zero),
            Self.window(2, "com.apple.Terminal", "zsh", .zero),
        ]
        let moves = restorePlan(for: layout, windows: moved, displays: displays)
        expect(moves.map(\.handle) == [1, 2], "every window moves")
        expect(moves.map(\.frame) == saved.map(\.frame), "frames round-trip exactly")
        expect(
            restorePlan(for: layout, windows: saved, displays: displays).isEmpty,
            "windows in place stay put")
    }

    mutating func restoreMatchesTitlesBeforeOrder() throws {
        let displays = DisplayArrangement(displays: [Self.laptop])!
        let saved = [
            Self.window(0, "app", "Renamed", CGRect(x: 0, y: 33, width: 500, height: 500)),
            Self.window(0, "app", "Notes", CGRect(x: 600, y: 33, width: 500, height: 500)),
        ]
        let layout = Layout(
            name: try LayoutName("L"), screens: captureScreens(of: saved, on: displays),
            autoRestore: false)
        let live = [
            Self.window(1, "app", "Other", .zero),
            Self.window(2, "app", "Notes", .zero),
            Self.window(3, "unrelated", "Notes", .zero),
        ]
        let moves = restorePlan(for: layout, windows: live, displays: displays)
        expect(moves.map(\.handle) == [2, 1], "title match claims first")
        expect(moves.map(\.frame) == [saved[1].frame, saved[0].frame], "frames follow matches")
    }

    mutating func restoreScalesWindowsFromMissingDisplayOntoMain() throws {
        let placement = WindowPlacement(
            bundleID: "app", title: "", relativeFrame: CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        let layout = Layout(
            name: try LayoutName("Desk"), screens: [Self.screen(Self.monitor, [placement])],
            autoRestore: false)
        let moves = restorePlan(
            for: layout, windows: [Self.window(1, "app", "", .zero)],
            displays: DisplayArrangement(displays: [Self.laptop])!)
        expect(
            moves.map(\.frame) == [CGRect(x: 756, y: 33, width: 756, height: 949)],
            "scaled onto main display")
    }

    mutating func openingAppsLeaveOnceTheirWindowsSettle() throws {
        let start = ContinuousClock.now
        func at(_ milliseconds: Int64) -> ContinuousClock.Instant {
            start + .milliseconds(milliseconds)
        }
        var opening = OpeningApps(["growing", "single", "none"], at: start)

        opening.observe(["growing", "single"], at: at(1000))
        opening.observe(["growing", "single", "growing"], at: at(2500))
        expect(opening.bundleIDs == ["growing", "single", "none"], "new windows keep apps watched")
        opening.observe(["growing", "single", "growing"], at: at(3000))
        expect(
            opening.bundleIDs == ["growing", "none"], "settling counts from the last new window")
        opening.observe(["growing", "growing"], at: at(4500))
        expect(opening.bundleIDs == ["none"], "a steady window count leaves")
        opening.observe([], at: at(14_999))
        expect(opening.bundleIDs == ["none"], "an app with no window waits")
        opening.observe([], at: start + OpeningApps.timeout)
        expect(opening.bundleIDs.isEmpty, "the timeout ends the watch")
    }

    mutating func identicalMonitorsGetDistinctIDsLeftToRight() throws {
        let left = LiveDisplay(
            id: Self.monitor.id, name: Self.monitor.name,
            frame: CGRect(x: -2560, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: -2560, y: 25, width: 2560, height: 1415))
        let displays = DisplayArrangement(displays: [Self.laptop, Self.monitor, left])!
        expect(
            displays.all.map(\.id.rawValue) == ["laptop", "monitor#2", "monitor"],
            "suffixes number left to right")
        expect(DisplayArrangement(displays: []) == nil, "no displays, no arrangement")
    }

    mutating func replacingScreensKeepsAutoRestoreAndTakesItOver() throws {
        let desk = try LayoutName("Desk")
        let docked = try LayoutName("Docked")
        var library = LayoutLibrary()
        try library.add(desk, screens: [Self.screen(Self.laptop)])
        try library.add(docked, screens: [Self.screen(Self.laptop), Self.screen(Self.monitor)])
        try library.setAutoRestore(desk, true)
        try library.setAutoRestore(docked, true)

        try library.replaceScreens(
            of: desk, with: [Self.screen(Self.laptop), Self.screen(Self.monitor)])
        expect(
            library.layouts.map(\.autoRestore) == [true, false],
            "replaced layout takes over auto-restore")
        expect(
            try library.layout(named: desk).displaySet == [Self.laptop.id, Self.monitor.id],
            "screens replaced")
    }

    mutating func autoRestoreIsExclusivePerDisplaySet() throws {
        let focus = try LayoutName("Focus")
        let wide = try LayoutName("Wide")
        let travel = try LayoutName("Travel")
        var library = LayoutLibrary()
        try library.add(focus, screens: [Self.screen(Self.laptop), Self.screen(Self.monitor)])
        try library.add(wide, screens: [Self.screen(Self.monitor), Self.screen(Self.laptop)])
        try library.add(travel, screens: [Self.screen(Self.laptop)])
        try library.setAutoRestore(focus, true)
        try library.setAutoRestore(travel, true)
        try library.setAutoRestore(wide, true)

        expect(
            library.layouts.map(\.autoRestore) == [false, true, true], "one owner per display set")
        expect(
            library.autoRestoreLayout(for: [Self.laptop.id, Self.monitor.id])?.name == wide,
            "both displays")
        expect(library.autoRestoreLayout(for: [Self.laptop.id])?.name == travel, "laptop only")
        expect(library.autoRestoreLayout(for: [Self.monitor.id]) == nil, "unsaved display set")
    }

    mutating func namesAreValidatedAndUnique() throws {
        expect(.invalidName) { _ = try LayoutName(" \n") }
        expect(.invalidName) { _ = try LayoutName("Tab\there") }
        expect(.invalidName) { _ = try LayoutName(String(repeating: "é", count: 64)) }
        expect(
            try LayoutName(String(repeating: "é", count: 63) + "e").rawValue.utf8.count == 127,
            "127 bytes fit")
        let desk = try LayoutName(" Desk ")
        expect(desk.rawValue == "Desk", "names are trimmed")
        expect(try LayoutName("Work 👩‍💻").rawValue == "Work 👩‍💻", "emoji joiners are allowed")

        let couch = try LayoutName("Couch")
        var library = LayoutLibrary()
        try library.add(desk, screens: [])
        try library.add(couch, screens: [])
        expect(.duplicateName(desk)) { try library.add(desk, screens: []) }
        expect(.duplicateName(desk)) { try library.rename(couch, to: desk) }
        expect(.unknownLayout(try LayoutName("Gone"))) { try library.delete(LayoutName("Gone")) }
        expect(library.layouts.map(\.name) == [desk, couch], "failed mutations change nothing")

        for index in 2..<LayoutLibrary.maxLayouts {
            try library.add(LayoutName("Layout \(index)"), screens: [])
        }
        expect(.tooManyLayouts) { try library.add(LayoutName("One too many"), screens: []) }
    }

    mutating func fileRoundTripsAndLoadRejectsConflicts() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID())/layouts.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        expect(
            try LayoutFile.load(from: url) == LayoutLibrary(), "missing file is an empty library")

        let a = try LayoutName("A")
        let placement = WindowPlacement(
            bundleID: "app", title: "t",
            relativeFrame: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        var library = LayoutLibrary()
        try library.add(a, screens: [Self.screen(Self.laptop, [placement])])
        try library.setAutoRestore(a, true)
        try LayoutFile.save(library, to: url)
        expect(try LayoutFile.load(from: url) == library, "file round-trips")

        let b = try LayoutName("B")
        let conflicting = [
            Layout(name: a, screens: [Self.screen(Self.laptop)], autoRestore: true),
            Layout(name: b, screens: [Self.screen(Self.laptop)], autoRestore: true),
        ]
        try JSONEncoder().encode(conflicting).write(to: url)
        expect(.conflictingAutoRestore(a, b)) { _ = try LayoutFile.load(from: url) }
    }

    mutating func argumentsParseStrictly() throws {
        let display = [
            "laptop", "Built-in Retina Display", "0", "0", "1512", "982", "0", "33", "1512", "949",
        ]
        let displays = DisplayArrangement(displays: [Self.laptop])!
        func parse(_ arguments: [String]) -> Command? { Command(arguments: arguments[...]) }

        expect(parse(["list"]) == .list, "list")
        expect(
            parse(["add", " Desk "] + display) == .add(" Desk ", displays), "add keeps the raw name"
        )
        expect(parse(["replace", "Desk"] + display) == .replace("Desk", displays), "replace")
        expect(parse(["restore", "Desk"] + display) == .restore("Desk", displays), "restore")
        expect(
            parse(["auto-restore"] + display + display.map { $0 == "laptop" ? "monitor" : $0 })
                != nil, "two displays")
        expect(parse(["rename", "Desk", "Couch"]) == .rename("Desk", to: "Couch"), "rename")
        expect(
            parse(["set-auto-restore", "Desk", "1"]) == .setAutoRestore("Desk", true),
            "set-auto-restore")
        expect(parse(["delete", "Desk"]) == .delete("Desk"), "delete")

        expect(parse([]) == nil, "no verb")
        expect(parse(["list", "extra"]) == nil, "extra operand")
        expect(parse(["auto-restore"]) == nil, "no displays")
        expect(parse(["add", "Desk"] + display.dropLast()) == nil, "partial display")
        expect(
            parse(["add", "Desk"] + display.map { $0 == "1512" ? "inf" : $0 }) == nil,
            "non-finite number")
        expect(
            parse(["add", "Desk"] + display.map { $0 == "949" ? "0" : $0 }) == nil,
            "empty visible frame")
        expect(parse(["set-auto-restore", "Desk", "yes"]) == nil, "non-binary flag")
    }

    mutating func outputMatchesProtocolFixture(path: String) throws {
        let desk = try LayoutName("Desk")
        var library = LayoutLibrary()
        try library.add(desk, screens: [Self.screen(Self.laptop), Self.screen(Self.monitor)])
        try library.setAutoRestore(desk, true)
        try library.add(LayoutName("Couch"), screens: [Self.screen(Self.laptop)])

        let output = Outcome.loaded(library, failure: LibraryError.duplicateName(desk)).output
        let fixture = try String(contentsOfFile: path, encoding: .utf8)
        expect(output == fixture, "output matches \(path):\n\(output)")
        expect(
            Outcome.unloaded(LibraryError.tooManyLayouts).output
                == "V\t1\nE\tMacLayoutManager keeps at most 64 layouts.\nD\n",
            "an unloaded library reports only its reason")

        expect(
            Outcome.field("a\tb\nc 👩‍💻", capacity: 32) == "a b c 👩‍💻",
            "control characters become spaces")
        expect(
            Outcome.field("ééé", capacity: 6) == "éé",
            "truncation keeps whole characters and the NUL")
    }
}
