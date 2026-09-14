import CoreGraphics
import Foundation

/// A helper invocation parsed from argv, per HelperProtocol.h. Names stay raw so that an invalid one
/// reaches the user as an `E` record rather than failing the run as malformed argv.
enum Command: Equatable {
    case list
    case add(String, DisplayArrangement)
    case replace(String, DisplayArrangement)
    case restore(String, DisplayArrangement)
    case autoRestore(DisplayArrangement)
    case rename(String, to: String)
    case setAutoRestore(String, Bool)
    case delete(String)

    init?(arguments: ArraySlice<String>) {
        guard let verb = arguments.first else { return nil }
        let operands = Array(arguments.dropFirst())
        let displays = { (skipped: Int) in
            DisplayArrangement(arguments: operands.dropFirst(skipped))
        }
        let command: Command? =
            switch (verb, operands.count) {
            case (MLMVerbList, 0): .list
            case (MLMVerbAdd, 1...): displays(1).map { .add(operands[0], $0) }
            case (MLMVerbReplace, 1...): displays(1).map { .replace(operands[0], $0) }
            case (MLMVerbRestore, 1...): displays(1).map { .restore(operands[0], $0) }
            case (MLMVerbAutoRestore, _): displays(0).map { .autoRestore($0) }
            case (MLMVerbRename, 2): .rename(operands[0], to: operands[1])
            case (MLMVerbSetAutoRestore, 2):
                ["0": false, "1": true][operands[1]].map { .setAutoRestore(operands[0], $0) }
            case (MLMVerbDelete, 1): .delete(operands[0])
            default: nil
            }
        guard let command else { return nil }
        self = command
    }
}

extension DisplayArrangement {
    /// `MLMDisplayArgumentCount` arguments per display. Nil for no displays, a partial display, or a
    /// non-finite or empty rect.
    init?(arguments: ArraySlice<String>) {
        let fields = Array(arguments)
        guard fields.count % MLMDisplayArgumentCount == 0 else { return nil }
        var displays: [LiveDisplay] = []
        for start in stride(from: 0, to: fields.count, by: MLMDisplayArgumentCount) {
            let numbers = fields[start + 2..<start + MLMDisplayArgumentCount].compactMap(
                Double.init
            ).filter(\.isFinite)
            guard !fields[start].isEmpty, numbers.count == 8,
                numbers[2] > 0, numbers[3] > 0, numbers[6] > 0, numbers[7] > 0
            else { return nil }
            displays.append(
                LiveDisplay(
                    id: DisplayID(rawValue: fields[start]),
                    name: fields[start + 1],
                    frame: CGRect(
                        x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]),
                    visibleFrame: CGRect(
                        x: numbers[4], y: numbers[5], width: numbers[6], height: numbers[7])
                ))
        }
        self.init(displays: displays)
    }
}

/// What one helper run reports. A run that loaded no library always carries the reason, which is the
/// header's "E required without S" rule.
enum Outcome {
    case loaded(LayoutLibrary, failure: (any Error)?)
    case unloaded(any Error)

    /// The complete output HelperProtocol.h specifies.
    var output: String {
        var output = Self.record("V", "1")
        switch self {
        case .loaded(let library, let failure):
            output += Self.record("S", String(library.layouts.count))
            for layout in library.layouts {
                output += Self.record(
                    "L", layout.name.rawValue, layout.autoRestore ? "1" : "0",
                    Self.field(
                        layout.screens.map(\.displayName).joined(separator: " + "),
                        capacity: MLMDisplaysCapacity))
            }
            if let failure {
                output += Self.record(
                    "E", Self.field(failure.localizedDescription, capacity: MLMMessageCapacity))
            }
        case .unloaded(let error):
            output += Self.record(
                "E", Self.field(error.localizedDescription, capacity: MLMMessageCapacity))
        }
        return output + Self.record("D")
    }

    private static func record(_ fields: String...) -> String {
        fields.joined(separator: "\t") + "\n"
    }

    /// `text` with control characters turned into spaces, cut at a character boundary to fit a C field
    /// of `capacity` bytes including its NUL.
    static func field(_ text: String, capacity: Int) -> String {
        var result = ""
        var used = 0
        for character in text {
            let piece =
                character.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                ? " " : String(character)
            used += piece.utf8.count
            guard used < capacity else { break }
            result += piece
        }
        return result
    }
}
