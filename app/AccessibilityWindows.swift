import ApplicationServices
import CoreGraphics
import Foundation

struct AXWindow {
    let element: AXUIElement
    let pid: pid_t
}

/// A geometry type and the `AXValueType` that carries it, so a read can't ask for one and decode the
/// other.
protocol AXGeometry {
    static var axType: AXValueType { get }
    static var zero: Self { get }
}

extension CGPoint: AXGeometry {
    static var axType: AXValueType { .cgPoint }
}

extension CGSize: AXGeometry {
    static var axType: AXValueType { .cgSize }
}

enum AccessibilityError: LocalizedError {
    case notTrusted

    var errorDescription: String? {
        "MacLayoutManager needs Accessibility access to read and move windows. Enable it in System Settings → Privacy & Security → Accessibility."
    }
}

/// Reads and moves windows without AppKit, so the helper pays for CoreGraphics and HIServices only.
enum AccessibilityWindows {
    /// One pass over the windows of apps whose bundle ID passes `include`.
    struct Scan {
        /// Standard, non-minimized, non-full-screen windows, front to back within each app.
        let movable: [LiveWindow<AXWindow>]
        /// Apps owning a standard window, minimized and full-screen ones included.
        let owners: Set<String>
    }

    static func scan(where include: (_ bundleID: String) -> Bool) throws -> Scan {
        // Caps each call into another app, so an unresponsive app stalls a run by at most a second.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1)
        // One round trip per window; a missing attribute comes back as an error value in its slot.
        let attributes =
            [
                kAXSubroleAttribute, kAXMinimizedAttribute, "AXFullScreen", kAXPositionAttribute,
                kAXSizeAttribute,
                kAXTitleAttribute,
            ] as CFArray

        var movable: [LiveWindow<AXWindow>] = []
        var owners = Set<String>()
        for (pid, bundleID) in appsWithWindows(where: include) {
            for window in try windows(of: pid) {
                var copied: CFArray?
                guard
                    AXUIElementCopyMultipleAttributeValues(window, attributes, [], &copied)
                        == .success,
                    let values = copied as? [AnyObject], values.count == 6,
                    values[0] as? String == kAXStandardWindowSubrole
                else { continue }
                owners.insert(bundleID)
                guard values[1] as? Bool != true,
                    values[2] as? Bool != true,
                    let origin: CGPoint = geometry(values[3]),
                    let size: CGSize = geometry(values[4])
                else { continue }
                movable.append(
                    LiveWindow(
                        handle: AXWindow(element: window, pid: pid),
                        bundleID: bundleID,
                        title: values[5] as? String ?? "",
                        frame: CGRect(origin: origin, size: size)
                    ))
            }
        }
        return Scan(movable: movable, owners: owners)
    }

    static func apply(_ moves: [WindowMove<AXWindow>]) {
        for (pid, appMoves) in Dictionary(grouping: moves, by: \.handle.pid) {
            // Apps with enhanced UI on (Chromium and Electron while assistive tech runs) animate frame
            // changes and drop the later ones.
            let app = AXUIElementCreateApplication(pid)
            let enhancedUI = "AXEnhancedUserInterface" as CFString
            var value: CFTypeRef?
            let hadEnhancedUI =
                AXUIElementCopyAttributeValue(app, enhancedUI, &value) == .success
                && value as? Bool == true
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

    /// Owners of normal-layer windows, on screen or not, since a hidden app keeps its windows off screen.
    /// Apps with no window at all cost no Accessibility round trip.
    private static func appsWithWindows(where include: (String) -> Bool) -> [(
        pid: pid_t, bundleID: String
    )] {
        // Walked as Foundation objects; bridging every entry to a Swift dictionary first costs more.
        let info = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as NSArray?
        var seen = Set<pid_t>()
        return (info ?? []).compactMap { entry in
            guard let window = entry as? NSDictionary,
                window[kCGWindowLayer] as? Int == 0,
                let pid = window[kCGWindowOwnerPID] as? pid_t,
                seen.insert(pid).inserted,
                let bundleID = bundleIdentifier(of: pid),
                include(bundleID)
            else { return nil }
            return (pid, bundleID)
        }
    }

    /// The app's windows. The helper checks no trust up front: without Accessibility access the first
    /// call into any app fails with `apiDisabled`.
    private static func windows(of pid: pid_t) throws -> [AXUIElement] {
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value)
        {
        case .success: return value as? [AXUIElement] ?? []
        case .apiDisabled: throw AccessibilityError.notTrusted
        default: return []
        }
    }

    /// The identifier of the bundle whose `Contents/MacOS` holds the process's executable.
    private static func bundleIdentifier(of pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE, which Swift can't import.
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
        guard let executable = path.range(of: "/Contents/MacOS/", options: .backwards) else {
            return nil
        }
        return Bundle(path: String(path[..<executable.lowerBound]))?.bundleIdentifier
    }

    /// Resizes before and after moving: the first resize keeps the move from being clamped by the old
    /// display, the second applies the target display's constraints.
    private static func setFrame(of window: AXUIElement, to frame: CGRect) {
        var origin = frame.origin
        var size = frame.size
        guard let position = AXValueCreate(.cgPoint, &origin),
            let dimensions = AXValueCreate(.cgSize, &size)
        else { return }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions)
    }

    private static func geometry<T: AXGeometry & BitwiseCopyable>(_ value: AnyObject) -> T? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var result = T.zero
        return AXValueGetValue(value as! AXValue, T.axType, &result) ? result : nil
    }
}
