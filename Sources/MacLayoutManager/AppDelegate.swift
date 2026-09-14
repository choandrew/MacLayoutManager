import AppKit
import LayoutCore
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Wait after the last display reconfiguration so macOS finishes shuffling windows between displays before auto-restore moves them.
    private static let displaySettleDelay = Duration.seconds(2)

    private let libraryURL: URL
    private var library: LayoutLibrary
    private let statusItem: NSStatusItem
    private var pendingAutoRestore: Task<Void, Never>?

    init(library: LayoutLibrary, libraryURL: URL) {
        self.library = library
        self.libraryURL = libraryURL
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "MacLayoutManager")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        if !AXIsProcessTrusted() {
            requestAccessibility()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item("Save Current Layout…", #selector(saveLayout)))

        if !library.layouts.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Restore"))
            for layout in library.layouts {
                menu.addItem(restoreItem(layout))
            }
            menu.addItem(.separator())
            menu.addItem(submenuItem("Manage Layouts", library.layouts.map { manageItem($0) }))
        }

        menu.addItem(.separator())
        if !AXIsProcessTrusted() {
            menu.addItem(item("Grant Accessibility Access…", #selector(requestAccessibility)))
        }
        let launchAtLogin = item("Launch at Login", #selector(toggleLaunchAtLogin))
        launchAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launchAtLogin)
        menu.addItem(NSMenuItem(title: "Quit MacLayoutManager", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
    }

    private func restoreItem(_ layout: Layout) -> NSMenuItem {
        let displays = layout.screens.map(\.displayName).joined(separator: " + ")
        let restore = item(layout.name.rawValue, #selector(restoreLayout(_:)), layout.name)
        restore.subtitle = layout.autoRestore ? "Auto-restores · \(displays)" : displays
        return restore
    }

    private func manageItem(_ layout: Layout) -> NSMenuItem {
        let autoRestore = item("Auto-Restore on These Displays", #selector(toggleAutoRestore(_:)), layout.name)
        autoRestore.state = layout.autoRestore ? .on : .off
        return submenuItem(layout.name.rawValue, [
            autoRestore,
            .separator(),
            item("Rename…", #selector(renameLayout(_:)), layout.name),
            item("Delete…", #selector(deleteLayout(_:)), layout.name),
        ])
    }

    @objc private func saveLayout() {
        updateLibrary { library in
            guard let displays = Displays.current() else { return }
            let screens = captureScreens(of: try AccessibilityWindows.windows { _ in true }, on: displays)
            guard let name = try promptForName(title: "Save Current Layout", initial: "") else { return }
            if library.layout(named: name) == nil {
                try library.add(name, screens: screens)
            } else if confirm("Replace “\(name)”?", info: "Its saved windows will be replaced with the current ones.", action: "Replace") {
                try library.replaceScreens(of: name, with: screens)
            }
        }
    }

    @objc private func restoreLayout(_ sender: NSMenuItem) {
        guard let layout = layout(for: sender), let displays = Displays.current() else { return }
        do {
            try restore(layout, on: displays)
        } catch {
            showError(error)
        }
    }

    @objc private func toggleAutoRestore(_ sender: NSMenuItem) {
        guard let layout = layout(for: sender) else { return }
        updateLibrary { try $0.setAutoRestore(layout.name, !layout.autoRestore) }
    }

    @objc private func renameLayout(_ sender: NSMenuItem) {
        guard let layout = layout(for: sender) else { return }
        updateLibrary { library in
            guard let name = try promptForName(title: "Rename Layout", initial: layout.name.rawValue) else { return }
            try library.rename(layout.name, to: name)
        }
    }

    @objc private func deleteLayout(_ sender: NSMenuItem) {
        guard let layout = layout(for: sender), confirm("Delete “\(layout.name)”?", info: "This can't be undone.", action: "Delete") else { return }
        updateLibrary { try $0.delete(layout.name) }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        } catch {
            showError(error)
        }
    }

    @objc private func requestAccessibility() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    @objc private func screenParametersChanged() {
        pendingAutoRestore?.cancel()
        pendingAutoRestore = Task {
            try? await Task.sleep(for: Self.displaySettleDelay)
            guard !Task.isCancelled,
                  let displays = Displays.current(),
                  let layout = library.autoRestoreLayout(for: displays.ids)
            else { return }
            // Without Accessibility access nothing can move; the menu offers the grant instead of interrupting a display change.
            try? restore(layout, on: displays)
        }
    }

    private func restore(_ layout: Layout, on displays: DisplayArrangement) throws {
        let bundleIDs = Set(layout.screens.flatMap { $0.windows.map(\.bundleID) })
        let windows = try AccessibilityWindows.windows { bundleIDs.contains($0) }
        AccessibilityWindows.apply(restorePlan(for: layout, windows: windows, displays: displays))
    }

    /// Runs `change` on a copy of the library and saves the copy if it changed, showing any error instead.
    private func updateLibrary(_ change: (inout LayoutLibrary) throws -> Void) {
        do {
            var updated = library
            try change(&updated)
            guard updated != library else { return }
            try LayoutFile.save(updated, to: libraryURL)
            library = updated
        } catch {
            showError(error)
        }
    }

    private func layout(for sender: NSMenuItem) -> Layout? {
        (sender.representedObject as? LayoutName).flatMap { library.layout(named: $0) }
    }

    private func item(_ title: String, _ action: Selector, _ layout: LayoutName? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = layout
        return item
    }

    private func submenuItem(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = NSMenu()
        item.submenu?.items = items
        return item
    }

    /// The entered name, or nil if cancelled.
    private func promptForName(title: String, initial: String) throws -> LayoutName? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        field.placeholderString = "Layout name"
        return try confirm(title, action: "Save", accessory: field) ? LayoutName(field.stringValue) : nil
    }

    /// Shows a modal alert and returns whether the user chose `action` over Cancel.
    private func confirm(_ message: String, info: String = "", action: String, accessory: NSView? = nil) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.accessoryView = accessory
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = accessory
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showError(_ error: any Error) {
        NSApp.activate()
        NSAlert(error: error).runModal()
    }
}
