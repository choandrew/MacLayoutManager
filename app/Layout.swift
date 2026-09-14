import CoreGraphics
import Foundation

/// A display's CoreGraphics UUID, stable across reboots and reconnections. Identical monitors can
/// share one, so `DisplayArrangement` suffixes repeats with `#n` by screen position.
struct DisplayID: RawRepresentable, Hashable, Codable {
    let rawValue: String
}

/// A layout's unique name: trimmed, non-empty, and within `maxBytes` UTF-8 bytes with no control
/// characters, so it fits the host's fixed-size record and a tab-separated helper field.
struct LayoutName: Hashable, Codable, CustomStringConvertible {
    static let maxBytes = MLMNameCapacity - 1

    let rawValue: String

    init(_ input: String) throws {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= Self.maxBytes,
            !trimmed.unicodeScalars.contains(where: \.isControl)
        else { throw LibraryError.invalidName }
        rawValue = trimmed
    }

    init(from decoder: any Decoder) throws {
        try self.init(String(from: decoder))
    }

    func encode(to encoder: any Encoder) throws {
        try rawValue.encode(to: encoder)
    }

    var description: String { rawValue }
}

extension Unicode.Scalar {
    /// A C0 or C1 control such as tab, line feed, or NUL. `CharacterSet.controlCharacters` also
    /// holds format characters like the zero-width joiner inside emoji such as 👩‍💻.
    var isControl: Bool { properties.generalCategory == .control }
}

/// A saved window position, matched back to a live window by app and title.
struct WindowPlacement: Codable, Equatable {
    let bundleID: String
    let title: String
    /// Frame as fractions of the display's visible frame, so it rescales when the resolution differs.
    let relativeFrame: CGRect
}

/// The windows saved on one display.
struct ScreenLayout: Codable, Equatable {
    let display: DisplayID
    let displayName: String
    let windows: [WindowPlacement]
}

struct Layout: Codable, Equatable {
    var name: LayoutName
    /// One entry per display connected at save time, including displays without windows.
    var screens: [ScreenLayout]
    /// Restore this layout whenever the displays reconfigure and the connected set equals `displaySet`.
    var autoRestore: Bool

    var displaySet: Set<DisplayID> { Set(screens.map(\.display)) }
}
