import Foundation

enum LibraryError: LocalizedError, Equatable {
    case invalidName
    case tooManyLayouts
    case duplicateName(LayoutName)
    case duplicateDisplay(LayoutName)
    case conflictingAutoRestore(LayoutName, LayoutName)
    case unknownLayout(LayoutName)

    var errorDescription: String? {
        switch self {
        case .invalidName:
            "Layout names can't be blank, longer than \(LayoutName.maxBytes) bytes, or contain tabs or line breaks."
        case .tooManyLayouts: "MacLayoutManager keeps at most \(LayoutLibrary.maxLayouts) layouts."
        case .duplicateName(let name): "A layout named “\(name)” already exists."
        case .duplicateDisplay(let name): "Layout “\(name)” lists the same display twice."
        case .conflictingAutoRestore(let first, let second):
            "Layouts “\(first)” and “\(second)” both auto-restore for the same displays."
        case .unknownLayout(let name): "No layout is named “\(name)”."
        }
    }
}

/// The saved layouts. Every mutation revalidates, so names are always unique, the count fits the
/// host's records, and each display set has at most one auto-restore layout.
struct LayoutLibrary: Equatable {
    static let maxLayouts = MLMMaxLayouts

    private(set) var layouts: [Layout]

    init() {
        layouts = []
    }

    init(layouts: [Layout]) throws {
        try Self.validate(layouts)
        self.layouts = layouts
    }

    func layout(named name: LayoutName) throws -> Layout {
        layouts[try index(of: name)]
    }

    func autoRestoreLayout(for displays: Set<DisplayID>) -> Layout? {
        layouts.first { $0.autoRestore && $0.displaySet == displays }
    }

    /// A new layout auto-restores, taking over from any other layout saved with the same displays.
    mutating func add(_ name: LayoutName, screens: [ScreenLayout]) throws {
        try modify { layouts in
            layouts.append(Layout(name: name, screens: screens, autoRestore: true))
            Self.claimAutoRestore(at: layouts.count - 1, in: &layouts)
        }
    }

    /// A replaced layout auto-restores like a new one, taking over from any other layout saved with the
    /// new displays.
    mutating func replaceScreens(of name: LayoutName, with screens: [ScreenLayout]) throws {
        try modify(named: name) { layouts, i in
            layouts[i].screens = screens
            Self.claimAutoRestore(at: i, in: &layouts)
        }
    }

    mutating func rename(_ name: LayoutName, to newName: LayoutName) throws {
        try modify(named: name) { layouts, i in layouts[i].name = newName }
    }

    /// Enabling auto-restore disables it on any other layout saved with the same displays.
    mutating func setAutoRestore(_ name: LayoutName, _ enabled: Bool) throws {
        try modify(named: name) { layouts, i in
            if enabled {
                Self.claimAutoRestore(at: i, in: &layouts)
            } else {
                layouts[i].autoRestore = false
            }
        }
    }

    mutating func delete(_ name: LayoutName) throws {
        try modify(named: name) { layouts, i in layouts.remove(at: i) }
    }

    private func index(of name: LayoutName) throws -> Int {
        guard let i = layouts.firstIndex(where: { $0.name == name }) else {
            throw LibraryError.unknownLayout(name)
        }
        return i
    }

    private mutating func modify(named name: LayoutName, _ change: (inout [Layout], Int) -> Void)
        throws
    {
        let i = try index(of: name)
        try modify { change(&$0, i) }
    }

    /// Applies `change` to a copy of the layouts and keeps the copy only if it validates.
    private mutating func modify(_ change: (inout [Layout]) -> Void) throws {
        var layouts = self.layouts
        change(&layouts)
        self = try LayoutLibrary(layouts: layouts)
    }

    private static func claimAutoRestore(at owner: Int, in layouts: inout [Layout]) {
        let displays = layouts[owner].displaySet
        for i in layouts.indices where layouts[i].displaySet == displays {
            layouts[i].autoRestore = i == owner
        }
    }

    private static func validate(_ layouts: [Layout]) throws {
        guard layouts.count <= maxLayouts else { throw LibraryError.tooManyLayouts }
        var names = Set<LayoutName>()
        var autoRestoreOwners: [Set<DisplayID>: LayoutName] = [:]
        for layout in layouts {
            guard names.insert(layout.name).inserted else {
                throw LibraryError.duplicateName(layout.name)
            }
            guard layout.displaySet.count == layout.screens.count else {
                throw LibraryError.duplicateDisplay(layout.name)
            }
            if layout.autoRestore,
                let other = autoRestoreOwners.updateValue(layout.name, forKey: layout.displaySet)
            {
                throw LibraryError.conflictingAutoRestore(other, layout.name)
            }
        }
    }
}

extension LayoutLibrary: Codable {
    init(from decoder: any Decoder) throws {
        try self.init(layouts: [Layout](from: decoder))
    }

    func encode(to encoder: any Encoder) throws {
        try layouts.encode(to: encoder)
    }
}

enum LayoutFile {
    static func load(from url: URL) throws -> LayoutLibrary {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return LayoutLibrary()
        }
        return try JSONDecoder().decode(LayoutLibrary.self, from: data)
    }

    /// The directory must exist; the helper creates it when it takes the lock.
    static func save(_ library: LayoutLibrary, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(library).write(to: url, options: .atomic)
    }
}
