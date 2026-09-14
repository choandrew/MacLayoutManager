import CoreGraphics
import Foundation

/// A display's CoreGraphics UUID, stable across reboots and reconnections.
public struct DisplayID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// A layout's unique name: non-empty, with no surrounding whitespace.
public struct LayoutName: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    /// Trims surrounding whitespace.
    public init(_ input: String) throws {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LibraryError.blankName }
        rawValue = trimmed
    }

    public init(from decoder: any Decoder) throws {
        try self.init(String(from: decoder))
    }

    public func encode(to encoder: any Encoder) throws {
        try rawValue.encode(to: encoder)
    }

    public var description: String { rawValue }
}

/// A saved window position, matched back to a live window by app and title.
public struct WindowPlacement: Codable, Equatable, Sendable {
    public let bundleID: String
    public let title: String
    /// Frame as fractions of the display's visible frame, so it rescales when the resolution differs.
    public let relativeFrame: CGRect
}

/// The windows saved on one display.
public struct ScreenLayout: Codable, Equatable, Sendable {
    public let display: DisplayID
    public let displayName: String
    public let windows: [WindowPlacement]
}

public struct Layout: Codable, Equatable, Sendable {
    public internal(set) var name: LayoutName
    /// One entry per display connected at save time, including displays without windows.
    public internal(set) var screens: [ScreenLayout]
    /// Restore this layout whenever the displays reconfigure and the connected set equals `displaySet`.
    public internal(set) var autoRestore: Bool

    public var displaySet: Set<DisplayID> { Set(screens.map(\.display)) }
}
