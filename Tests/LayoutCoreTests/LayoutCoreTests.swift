import CoreGraphics
import Foundation
import Testing
@testable import LayoutCore

private let laptop = LiveDisplay(
    id: DisplayID(rawValue: "laptop"), name: "Built-in",
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    visibleFrame: CGRect(x: 0, y: 33, width: 1512, height: 949)
)
private let monitor = LiveDisplay(
    id: DisplayID(rawValue: "monitor"), name: "Monitor",
    frame: CGRect(x: 1512, y: -500, width: 2560, height: 1440),
    visibleFrame: CGRect(x: 1512, y: -475, width: 2560, height: 1415)
)

private func window(_ handle: Int, _ bundleID: String, _ title: String, _ frame: CGRect) -> LiveWindow<Int> {
    LiveWindow(handle: handle, bundleID: bundleID, title: title, frame: frame)
}

private func screen(_ display: LiveDisplay, _ windows: [WindowPlacement] = []) -> ScreenLayout {
    ScreenLayout(display: display.id, displayName: display.name, windows: windows)
}

@Test func captureThenRestoreOnSameDisplaysReproducesFrames() throws {
    let displays = try #require(DisplayArrangement(displays: [laptop, monitor]))
    let saved = [
        window(1, "com.apple.Safari", "Docs", CGRect(x: 100, y: 60, width: 900, height: 700)),
        // Mostly on the monitor, so it belongs to the monitor.
        window(2, "com.apple.Terminal", "zsh", CGRect(x: 1400, y: 100, width: 800, height: 600)),
    ]
    let screens = captureScreens(of: saved, on: displays)
    #expect(screens.map(\.display) == [laptop.id, monitor.id])
    #expect(screens.map { $0.windows.map(\.title) } == [["Docs"], ["zsh"]])

    let layout = Layout(name: try LayoutName("Desk"), screens: screens, autoRestore: false)
    let moved = [window(1, "com.apple.Safari", "Docs", .zero), window(2, "com.apple.Terminal", "zsh", .zero)]
    let moves = restorePlan(for: layout, windows: moved, displays: displays)
    #expect(moves.map(\.handle) == [1, 2])
    #expect(moves.map(\.frame) == saved.map(\.frame))
    #expect(restorePlan(for: layout, windows: saved, displays: displays).isEmpty)
}

@Test func restoreMatchesTitlesBeforeOrder() throws {
    let displays = try #require(DisplayArrangement(displays: [laptop]))
    let saved = [
        window(0, "app", "Renamed", CGRect(x: 0, y: 33, width: 500, height: 500)),
        window(0, "app", "Notes", CGRect(x: 600, y: 33, width: 500, height: 500)),
    ]
    let layout = Layout(name: try LayoutName("L"), screens: captureScreens(of: saved, on: displays), autoRestore: false)
    let live = [
        window(1, "app", "Other", .zero),
        window(2, "app", "Notes", .zero),
        window(3, "unrelated", "Notes", .zero),
    ]
    let moves = restorePlan(for: layout, windows: live, displays: displays)
    #expect(moves.map(\.handle) == [2, 1])
    #expect(moves.map(\.frame) == [saved[1].frame, saved[0].frame])
}

@Test func restoreScalesWindowsFromMissingDisplayOntoMain() throws {
    let layout = Layout(
        name: try LayoutName("Desk"),
        screens: [screen(monitor, [WindowPlacement(bundleID: "app", title: "", relativeFrame: CGRect(x: 0.5, y: 0, width: 0.5, height: 1))])],
        autoRestore: false
    )
    let displays = try #require(DisplayArrangement(displays: [laptop]))
    let moves = restorePlan(for: layout, windows: [window(1, "app", "", .zero)], displays: displays)
    #expect(moves.map(\.frame) == [CGRect(x: 756, y: 33, width: 756, height: 949)])
}

@Test func identicalMonitorsGetDistinctIDsLeftToRight() throws {
    let left = LiveDisplay(id: monitor.id, name: "Monitor", frame: CGRect(x: -2560, y: 0, width: 2560, height: 1440), visibleFrame: .zero)
    let displays = try #require(DisplayArrangement(displays: [laptop, monitor, left]))
    #expect(displays.all.map(\.id.rawValue) == ["laptop", "monitor#2", "monitor"])
}

@Test func replacingScreensKeepsAutoRestoreAndTakesItOverForNewDisplays() throws {
    let desk = try LayoutName("Desk")
    let docked = try LayoutName("Docked")
    var library = LayoutLibrary()
    try library.add(desk, screens: [screen(laptop)])
    try library.add(docked, screens: [screen(laptop), screen(monitor)])
    try library.setAutoRestore(desk, true)
    try library.setAutoRestore(docked, true)

    try library.replaceScreens(of: desk, with: [screen(laptop), screen(monitor)])
    #expect(library.layouts.map(\.autoRestore) == [true, false])
    #expect(library.layout(named: desk)?.displaySet == [laptop.id, monitor.id])
}

@Test func autoRestoreIsExclusivePerDisplaySet() throws {
    let focus = try LayoutName("Focus")
    let wide = try LayoutName("Wide")
    let travel = try LayoutName("Travel")
    var library = LayoutLibrary()
    try library.add(focus, screens: [screen(laptop), screen(monitor)])
    try library.add(wide, screens: [screen(monitor), screen(laptop)])
    try library.add(travel, screens: [screen(laptop)])
    try library.setAutoRestore(focus, true)
    try library.setAutoRestore(travel, true)
    try library.setAutoRestore(wide, true)

    #expect(library.layouts.map(\.autoRestore) == [false, true, true])
    #expect(library.autoRestoreLayout(for: [laptop.id, monitor.id])?.name == wide)
    #expect(library.autoRestoreLayout(for: [laptop.id])?.name == travel)
    #expect(library.autoRestoreLayout(for: [monitor.id]) == nil)
}

@Test func namesAreTrimmedNonBlankAndUnique() throws {
    #expect(throws: LibraryError.blankName) { try LayoutName(" \n") }
    let desk = try LayoutName(" Desk ")
    #expect(desk.rawValue == "Desk")

    let couch = try LayoutName("Couch")
    var library = LayoutLibrary()
    try library.add(desk, screens: [])
    try library.add(couch, screens: [])
    #expect(throws: LibraryError.duplicateName(desk)) { try library.add(desk, screens: []) }
    #expect(throws: LibraryError.duplicateName(desk)) { try library.rename(couch, to: desk) }
    #expect(library.layouts.map(\.name) == [desk, couch])
}

@Test func fileRoundTripsAndLoadRejectsConflictingAutoRestore() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID())/layouts.json")
    #expect(try LayoutFile.load(from: url) == LayoutLibrary())

    let a = try LayoutName("A")
    var library = LayoutLibrary()
    try library.add(a, screens: [screen(laptop, [WindowPlacement(bundleID: "app", title: "t", relativeFrame: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))])])
    try library.setAutoRestore(a, true)
    try LayoutFile.save(library, to: url)
    #expect(try LayoutFile.load(from: url) == library)

    let b = try LayoutName("B")
    let conflicting = [
        Layout(name: a, screens: [screen(laptop)], autoRestore: true),
        Layout(name: b, screens: [screen(laptop)], autoRestore: true),
    ]
    try JSONEncoder().encode(conflicting).write(to: url)
    #expect(throws: LibraryError.conflictingAutoRestore(a, b)) { try LayoutFile.load(from: url) }
}
