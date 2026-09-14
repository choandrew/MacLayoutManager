import CoreGraphics

/// Rects use the Accessibility coordinates HelperProtocol.h describes.
struct LiveDisplay: Equatable {
    let id: DisplayID
    let name: String
    let frame: CGRect
    /// `frame` minus the menu bar and Dock.
    let visibleFrame: CGRect
}

/// The connected displays, with IDs unique across `all`.
struct DisplayArrangement: Equatable {
    let main: LiveDisplay
    let secondary: [LiveDisplay]

    var all: [LiveDisplay] { [main] + secondary }
    var ids: Set<DisplayID> { Set(all.map(\.id)) }

    /// `displays` lists the main display first. Identical monitors can share a UUID, so repeats get a `#n` suffix numbered left to right.
    init?(displays: [LiveDisplay]) {
        var ids = displays.map(\.id)
        var occurrences: [DisplayID: Int] = [:]
        for i in displays.indices.sorted(by: {
            (displays[$0].frame.minX, displays[$0].frame.minY) < (
                displays[$1].frame.minX, displays[$1].frame.minY
            )
        }) {
            let count = occurrences[displays[i].id, default: 0] + 1
            occurrences[displays[i].id] = count
            if count > 1 {
                ids[i] = DisplayID(rawValue: "\(displays[i].id.rawValue)#\(count)")
            }
        }
        let unique = zip(displays, ids).map {
            LiveDisplay(id: $1, name: $0.name, frame: $0.frame, visibleFrame: $0.visibleFrame)
        }
        guard let main = unique.first else { return nil }
        self.main = main
        secondary = Array(unique.dropFirst())
    }

    /// The display showing the largest part of `frame`; ties, including frames on no display, go to the main display.
    func display(containing frame: CGRect) -> LiveDisplay {
        secondary.reduce(main) { best, display in
            display.frame.intersection(frame).area > best.frame.intersection(frame).area
                ? display : best
        }
    }
}

struct LiveWindow<Handle> {
    let handle: Handle
    let bundleID: String
    let title: String
    let frame: CGRect
}

struct WindowMove<Handle> {
    let handle: Handle
    let frame: CGRect
}

func captureScreens<Handle>(of windows: [LiveWindow<Handle>], on displays: DisplayArrangement)
    -> [ScreenLayout]
{
    let windowsByDisplay = Dictionary(grouping: windows) {
        displays.display(containing: $0.frame).id
    }
    return displays.all.map { display in
        ScreenLayout(
            display: display.id,
            displayName: display.name,
            windows: windowsByDisplay[display.id, default: []].map {
                WindowPlacement(
                    bundleID: $0.bundleID, title: $0.title,
                    relativeFrame: $0.frame.relative(to: display.visibleFrame))
            }
        )
    }
}

/// Pairs each placement in `layout` with a live window of the same app, by identical title first and then in `windows` order.
/// Placements saved on a display that is no longer connected land on the main display. Windows already in place get no move.
func restorePlan<Handle>(
    for layout: Layout, windows: [LiveWindow<Handle>], displays: DisplayArrangement
) -> [WindowMove<Handle>] {
    let liveDisplays = Dictionary(uniqueKeysWithValues: displays.all.map { ($0.id, $0) })
    let targets = layout.screens.flatMap { screen in
        let visibleFrame = (liveDisplays[screen.display] ?? displays.main).visibleFrame
        return screen.windows.map {
            (placement: $0, frame: $0.relativeFrame.absolute(in: visibleFrame))
        }
    }

    var unclaimed = Dictionary(grouping: windows, by: \.bundleID).mapValues { $0[...] }
    var moves: [WindowMove<Handle>] = []
    func claim(_ window: LiveWindow<Handle>, for frame: CGRect) {
        if window.frame != frame {
            moves.append(WindowMove(handle: window.handle, frame: frame))
        }
    }

    var unmatchedTargets: [(placement: WindowPlacement, frame: CGRect)] = []
    for target in targets {
        if let i = unclaimed[target.placement.bundleID]?.firstIndex(where: {
            $0.title == target.placement.title
        }),
            let window = unclaimed[target.placement.bundleID]?.remove(at: i)
        {
            claim(window, for: target.frame)
        } else {
            unmatchedTargets.append(target)
        }
    }
    for target in unmatchedTargets {
        if let window = unclaimed[target.placement.bundleID]?.popFirst() {
            claim(window, for: target.frame)
        }
    }
    return moves
}

/// The apps a restore opened, watched while their windows appear. An app leaves the watch once it
/// shows as many windows as the layout saved for it, or shows some and gains none for `settleTime`,
/// since an app that restores no state opens a single window. Every app leaves at `timeout`, since
/// an app can open no window at all.
struct OpeningApps {
    static let settleTime = Duration.seconds(2)
    static let timeout = Duration.seconds(15)

    private let started: ContinuousClock.Instant
    private let savedCounts: [String: Int]
    /// Each watched app's latest window count and when that count last changed.
    private var watched: [String: (count: Int, since: ContinuousClock.Instant)]

    init(_ bundleIDs: Set<String>, in layout: Layout, at now: ContinuousClock.Instant) {
        started = now
        savedCounts = Dictionary(grouping: layout.screens.flatMap(\.windows), by: \.bundleID)
            .mapValues(\.count)
        watched = Dictionary(uniqueKeysWithValues: bundleIDs.map { ($0, (0, now)) })
    }

    var bundleIDs: Set<String> { Set(watched.keys) }

    /// Records the watched apps' windows seen at `now` and drops the apps that are done.
    mutating func observe<Handle>(_ windows: [LiveWindow<Handle>], at now: ContinuousClock.Instant)
    {
        guard now - started < Self.timeout else {
            watched = [:]
            return
        }
        let counts = Dictionary(grouping: windows, by: \.bundleID).mapValues(\.count)
        for (bundleID, last) in watched {
            let count = counts[bundleID, default: 0]
            let since = count == last.count ? last.since : now
            let done =
                count >= savedCounts[bundleID, default: 0]
                || (count > 0 && now - since >= Self.settleTime)
            watched[bundleID] = done ? nil : (count, since)
        }
    }
}

extension CGRect {
    var area: CGFloat { width * height }

    /// This rect as fractions of `container`.
    func relative(to container: CGRect) -> CGRect {
        CGRect(
            x: (minX - container.minX) / container.width,
            y: (minY - container.minY) / container.height,
            width: width / container.width,
            height: height / container.height
        )
    }

    /// The inverse of `relative(to:)`, rounded to whole points.
    func absolute(in container: CGRect) -> CGRect {
        CGRect(
            x: (container.minX + minX * container.width).rounded(),
            y: (container.minY + minY * container.height).rounded(),
            width: (width * container.width).rounded(),
            height: (height * container.height).rounded()
        )
    }
}
