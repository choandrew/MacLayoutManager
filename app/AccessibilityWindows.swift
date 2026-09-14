import ApplicationServices
import CoreGraphics
import Foundation
import Synchronization

struct AXWindow {
    let element: AXUIElement
    let pid: pid_t
}

/// A geometry type and the `AXValueType` that carries it, so a read or write can't pair one type
/// with the other's tag.
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

extension AXGeometry where Self: BitwiseCopyable {
    init?(axValue: AnyObject) {
        guard CFGetTypeID(axValue) == AXValueGetTypeID() else { return nil }
        var result = Self.zero
        guard AXValueGetValue(axValue as! AXValue, Self.axType, &result) else { return nil }
        self = result
    }

    var axValue: AXValue? {
        var copy = self
        return AXValueCreate(Self.axType, &copy)
    }
}

enum AccessibilityError: LocalizedError {
    case notTrusted

    var errorDescription: String? {
        "MacLayoutManager needs Accessibility access to read and move windows. Enable it in System Settings → Privacy & Security → Accessibility."
    }
}

/// Reads and moves windows without AppKit, so the helper pays for CoreGraphics and HIServices only.
enum AccessibilityWindows {
    /// Caps each call into another app, for the whole process.
    private static let messagingTimeout = Duration.seconds(1)

    /// One app's standard windows, read by the worker that handles that app.
    struct App {
        let bundleID: String
        /// Standard, non-minimized, non-full-screen windows, front to back.
        let movable: [LiveWindow<AXWindow>]
        /// Standard windows, minimized and full-screen ones included.
        let windowCount: Int
        /// Whether a call ran into the messaging timeout. A hung app gets no further calls this pass,
        /// so it stalls a run by about one timeout rather than one per call.
        let hung: Bool

        /// Moves this app's windows; call it from the worker that read them.
        func apply(_ moves: [WindowMove<AXWindow>]) {
            guard !hung else { return }
            for (pid, appMoves) in Dictionary(grouping: moves, by: \.window.handle.pid) {
                // Apps with enhanced UI on (Chromium and Electron while assistive tech runs) animate
                // frame changes and drop the later ones.
                let app = AXUIElementCreateApplication(pid)
                let enhancedUI = "AXEnhancedUserInterface" as CFString
                var value: CFTypeRef?
                let read = call { AXUIElementCopyAttributeValue(app, enhancedUI, &value) }
                guard !read.hung else { return }
                let hadEnhancedUI = read.status == .success && value as? Bool == true
                if hadEnhancedUI {
                    AXUIElementSetAttributeValue(app, enhancedUI, false as CFBoolean)
                }
                var appHung = false
                for move in appMoves where !appHung {
                    appHung = setFrame(
                        of: move.window.handle.element, from: move.window.frame, to: move.frame)
                }
                if hadEnhancedUI {
                    AXUIElementSetAttributeValue(app, enhancedUI, true as CFBoolean)
                }
                guard !appHung else { return }
            }
        }
    }

    /// Reads the windows of each app whose bundle ID passes `include` and runs `body` on them, each
    /// app on its own worker, up to one worker per CPU core, and returns the outputs in window list
    /// order. An app answers Accessibility calls one at a time on its main thread, so while the apps
    /// fit the cores a run lasts about as long as its slowest app rather than all apps together.
    /// `AXUIElement` is not `Sendable`, so each element stays on the worker that read it and only
    /// `body`'s output crosses threads.
    static func forEachApp<Output: Sendable>(
        where include: (_ bundleID: String) -> Bool,
        _ body: @Sendable (App) -> Output
    ) throws -> [Output] {
        AXUIElementSetMessagingTimeout(
            AXUIElementCreateSystemWide(), Float(messagingTimeout / .seconds(1)))
        let apps = appsWithWindows(where: include)
        let outputs = Mutex(
            [Result<Output, AccessibilityError>?](repeating: nil, count: apps.count))
        DispatchQueue.concurrentPerform(iterations: apps.count) { index in
            let output = Result { () throws(AccessibilityError) in
                try body(read(apps[index].bundleID, pids: apps[index].pids))
            }
            outputs.withLock { $0[index] = output }
        }
        return try outputs.withLock { $0 }.compactMap { try $0?.get() }
    }

    /// The bundle IDs among `bundleIDs` that a running process belongs to.
    static func runningApps(among bundleIDs: Set<String>) -> Set<String> {
        guard !bundleIDs.isEmpty else { return [] }
        // Room for processes that start between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(max(proc_listallpids(nil, 0), 0)) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Set(
            pids.prefix(Int(max(count, 0))).lazy.compactMap(bundleIdentifier(of:))
                .filter(bundleIDs.contains))
    }

    /// Bundle IDs in the order their first normal-layer window appears, each with its processes.
    /// Hidden apps keep their windows off screen, so off-screen windows count. Apps with no window
    /// at all cost no Accessibility round trip.
    private static func appsWithWindows(where include: (String) -> Bool) -> [(
        bundleID: String, pids: [pid_t]
    )] {
        // Walked as Foundation objects; bridging every entry to a Swift dictionary first costs more.
        let info = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as NSArray?
        var seen = Set<pid_t>()
        var apps: [(bundleID: String, pids: [pid_t])] = []
        var indices: [String: Int] = [:]
        for entry in info ?? [] {
            guard let window = entry as? NSDictionary,
                window[kCGWindowLayer] as? Int == 0,
                let pid = window[kCGWindowOwnerPID] as? pid_t,
                seen.insert(pid).inserted,
                let bundleID = bundleIdentifier(of: pid),
                include(bundleID)
            else { continue }
            if let index = indices[bundleID] {
                apps[index].pids.append(pid)
            } else {
                indices[bundleID] = apps.count
                apps.append((bundleID, [pid]))
            }
        }
        return apps
    }

    /// One round trip for each process's window list and one per window; a missing attribute comes
    /// back as an error value in its slot.
    private static func read(_ bundleID: String, pids: [pid_t]) throws(AccessibilityError) -> App {
        let attributes =
            [
                kAXSubroleAttribute, kAXMinimizedAttribute, "AXFullScreen", kAXPositionAttribute,
                kAXSizeAttribute, kAXTitleAttribute,
            ] as CFArray
        var movable: [LiveWindow<AXWindow>] = []
        var windowCount = 0
        func app(hung: Bool) -> App {
            App(bundleID: bundleID, movable: movable, windowCount: windowCount, hung: hung)
        }
        for pid in pids {
            var windows: CFTypeRef?
            let windowsCall = call {
                AXUIElementCopyAttributeValue(
                    AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &windows)
            }
            // The helper checks no trust up front: without Accessibility access the first call into
            // any app fails with `apiDisabled`.
            if windowsCall.status == .apiDisabled {
                throw .notTrusted
            }
            guard !windowsCall.hung else { return app(hung: true) }
            for window in windows as? [AXUIElement] ?? [] {
                var copied: CFArray?
                let attributesCall = call {
                    AXUIElementCopyMultipleAttributeValues(window, attributes, [], &copied)
                }
                guard !attributesCall.hung else { return app(hung: true) }
                guard attributesCall.status == .success,
                    let values = copied as? [AnyObject], values.count == 6,
                    values[0] as? String == kAXStandardWindowSubrole
                else { continue }
                windowCount += 1
                guard values[1] as? Bool != true,
                    values[2] as? Bool != true,
                    let origin = CGPoint(axValue: values[3]),
                    let size = CGSize(axValue: values[4])
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
        return app(hung: false)
    }

    /// Makes one call into an app and reports whether the app hung. An app that refuses a call fails
    /// at once, so a failure that waited at least half the messaging timeout means it stopped
    /// answering.
    private static func call(_ body: () -> AXError) -> (status: AXError, hung: Bool) {
        let start = ContinuousClock.now
        let status = body()
        return (status, status == .cannotComplete && .now - start >= messagingTimeout / 2)
    }

    /// The identifier of the app bundle whose `Contents/MacOS` holds the process's executable, or nil
    /// for an XPC service, which is part of another app rather than an app a layout can open.
    private static func bundleIdentifier(of pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE, which Swift can't import.
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
        guard let executable = path.range(of: "/Contents/MacOS/", options: .backwards) else {
            return nil
        }
        // Reading Info.plist directly is 2-3x faster than a cold `Bundle(path:)`.
        let plist = URL(filePath: path[..<executable.lowerBound] + "/Contents/Info.plist")
        guard let info = try? NSDictionary(contentsOf: plist, error: ()),
            info["CFBundlePackageType"] as? String != "XPC!"
        else { return nil }
        return info["CFBundleIdentifier"] as? String
    }

    /// Resizes before and after moving: the first resize keeps the move from being clamped by the old
    /// display, the second applies the target display's constraints. A window already at its target
    /// size skips the first resize, which would change nothing. Returns whether the app hung.
    private static func setFrame(of window: AXUIElement, from current: CGRect, to frame: CGRect)
        -> Bool
    {
        guard let position = frame.origin.axValue, let size = frame.size.axValue else {
            return false
        }
        var steps = [(kAXPositionAttribute, position), (kAXSizeAttribute, size)]
        if current.size != frame.size {
            steps.insert((kAXSizeAttribute, size), at: 0)
        }
        for (attribute, value) in steps
        where call({ AXUIElementSetAttributeValue(window, attribute as CFString, value) }).hung {
            return true
        }
        return false
    }
}
