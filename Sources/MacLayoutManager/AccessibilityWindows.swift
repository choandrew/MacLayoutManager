import AppKit
import ApplicationServices
import LayoutCore

struct AXWindow {
    let element: AXUIElement
    let app: AXUIElement
    let pid: pid_t
}

enum AccessibilityError: LocalizedError {
    case notTrusted

    var errorDescription: String? {
        "MacLayoutManager needs Accessibility access to read and move windows. Enable it in System Settings → Privacy & Security → Accessibility."
    }
}

@MainActor
enum AccessibilityWindows {
    /// Standard, non-minimized, non-full-screen windows of regular apps whose bundle ID passes `include`, front to back within each app.
    static func windows(where include: (_ bundleID: String) -> Bool) throws -> [LiveWindow<AXWindow>] {
        guard AXIsProcessTrusted() else { throw AccessibilityError.notTrusted }
        // Caps each call into another app, so an unresponsive app can't freeze the menu.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1)

        return NSWorkspace.shared.runningApplications.flatMap { app -> [LiveWindow<AXWindow>] in
            guard app.activationPolicy == .regular, let bundleID = app.bundleIdentifier, include(bundleID) else { return [] }
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            let windows: [AXUIElement] = value(of: kAXWindowsAttribute, on: appElement) ?? []
            return windows.compactMap { window in
                guard value(of: kAXSubroleAttribute, on: window) as String? == kAXStandardWindowSubrole,
                      value(of: kAXMinimizedAttribute, on: window) as Bool? != true,
                      value(of: "AXFullScreen", on: window) as Bool? != true,
                      let origin = geometry(of: kAXPositionAttribute, on: window, type: .cgPoint, initial: CGPoint.zero),
                      let size = geometry(of: kAXSizeAttribute, on: window, type: .cgSize, initial: CGSize.zero)
                else { return nil }
                return LiveWindow(
                    handle: AXWindow(element: window, app: appElement, pid: app.processIdentifier),
                    bundleID: bundleID,
                    title: value(of: kAXTitleAttribute, on: window) ?? "",
                    frame: CGRect(origin: origin, size: size)
                )
            }
        }
    }

    static func apply(_ moves: [WindowMove<AXWindow>]) {
        for appMoves in Dictionary(grouping: moves, by: \.handle.pid).values {
            // Apps with enhanced UI on (Chromium and Electron while assistive tech runs) animate frame changes and drop the later ones.
            let app = appMoves[0].handle.app
            let enhancedUI = "AXEnhancedUserInterface" as CFString
            let hadEnhancedUI = value(of: enhancedUI as String, on: app) as Bool? == true
            if hadEnhancedUI {
                AXUIElementSetAttributeValue(app, enhancedUI, false as CFBoolean)
            }
            for move in appMoves {
                setFrame(of: move.handle.element, to: move.frame)
            }
            if hadEnhancedUI {
                AXUIElementSetAttributeValue(app, enhancedUI, true as CFBoolean)
            }
        }
    }

    /// Resizes before and after moving: the first resize keeps the move from being clamped by the old display, the second applies the target display's constraints.
    private static func setFrame(of window: AXUIElement, to frame: CGRect) {
        var origin = frame.origin
        var size = frame.size
        guard let position = AXValueCreate(.cgPoint, &origin), let dimensions = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions)
    }

    private static func value<T>(of attribute: String, on element: AXUIElement) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func geometry<T: BitwiseCopyable>(of attribute: String, on element: AXUIElement, type: AXValueType, initial: T) -> T? {
        guard let raw: CFTypeRef = value(of: attribute, on: element), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var result = initial
        return AXValueGetValue(raw as! AXValue, type, &result) ? result : nil
    }
}
