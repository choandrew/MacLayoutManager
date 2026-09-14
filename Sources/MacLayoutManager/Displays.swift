import AppKit
import LayoutCore

@MainActor
enum Displays {
    /// The connected displays in Accessibility coordinates, or nil while none are usable (e.g. mid-reconfiguration).
    static func current() -> DisplayArrangement? {
        // NSScreen.screens[0] is the main display, whose top edge anchors both coordinate systems.
        guard let mainHeight = NSScreen.screens.first?.frame.height else { return nil }
        func flipped(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
        }

        var displays: [LiveDisplay] = []
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue()
            else { return nil }
            displays.append(LiveDisplay(
                id: DisplayID(rawValue: CFUUIDCreateString(nil, uuid) as String),
                name: screen.localizedName,
                frame: flipped(screen.frame),
                visibleFrame: flipped(screen.visibleFrame)
            ))
        }
        return DisplayArrangement(displays: displays)
    }
}
