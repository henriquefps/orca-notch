import Foundation

/// Where the island sits along the top edge of a screen: the default centered place, the clamp that keeps
/// it on screen, the position remembered per display, and the click-versus-drag decision.
enum IslandPlacement {
    /// Gap kept between the island and the screen's left and right edges.
    static let screenMargin: CGFloat = 8
    /// Pointer travel, in points, before a press on the closed island becomes a drag.
    static let dragThreshold: CGFloat = 4

    /// The default place: centered on the screen, which is the notch on a notched Mac.
    static func defaultCenterX(screenMinX: CGFloat, screenMaxX: CGFloat) -> CGFloat {
        (screenMinX + screenMaxX) / 2
    }

    /// `centerX` limited so an island of `islandWidth` stays inside the screen with `screenMargin` on both sides.
    /// An island wider than the screen allows is centered.
    static func clampedCenterX(_ centerX: CGFloat, islandWidth: CGFloat,
                               screenMinX: CGFloat, screenMaxX: CGFloat) -> CGFloat {
        let low = screenMinX + screenMargin + islandWidth / 2
        let high = screenMaxX - screenMargin - islandWidth / 2
        guard low <= high else { return defaultCenterX(screenMinX: screenMinX, screenMaxX: screenMaxX) }
        return min(max(centerX, low), high)
    }

    /// The center to use for a screen: the remembered offset from the screen's middle (nil = default),
    /// clamped for `islandWidth`. An offset stays valid after a resolution change because it is relative.
    static func centerX(storedOffset: CGFloat?, islandWidth: CGFloat,
                        screenMinX: CGFloat, screenMaxX: CGFloat) -> CGFloat {
        let middle = defaultCenterX(screenMinX: screenMinX, screenMaxX: screenMaxX)
        return clampedCenterX(middle + (storedOffset ?? 0), islandWidth: islandWidth,
                              screenMinX: screenMinX, screenMaxX: screenMaxX)
    }

    /// The offset from the screen's middle to remember for a dragged center.
    static func offset(forCenterX centerX: CGFloat, screenMinX: CGFloat, screenMaxX: CGFloat) -> CGFloat {
        centerX - defaultCenterX(screenMinX: screenMinX, screenMaxX: screenMaxX)
    }
}

/// The position remembered per display: `UserDefaults` key `islandPositions`, a dictionary from the display
/// identifier (its UUID) to the island's horizontal offset in points from the screen's middle. A display with
/// no entry uses the default centered place.
struct IslandPositionStore {
    static let defaultsKey = "islandPositions"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private var all: [String: Double] { defaults.dictionary(forKey: Self.defaultsKey) as? [String: Double] ?? [:] }

    func offset(for display: String?) -> CGFloat? {
        guard let display, let value = all[display] else { return nil }
        return CGFloat(value)
    }

    func setOffset(_ offset: CGFloat, for display: String?) {
        guard let display else { return }
        var positions = all
        positions[display] = Double(offset)
        defaults.set(positions, forKey: Self.defaultsKey)
    }

    func reset(for display: String?) {
        guard let display else { return }
        var positions = all
        positions[display] = nil
        defaults.set(positions, forKey: Self.defaultsKey)
    }
}

/// Click or drag: a press becomes a drag once the pointer has traveled `IslandPlacement.dragThreshold`.
/// From then on it stays a drag, even if the pointer comes back, so releasing never also counts as a click.
struct IslandDragTracker {
    private(set) var origin: CGPoint
    private(set) var isDragging = false

    init(origin: CGPoint) { self.origin = origin }

    /// Horizontal travel since the press once it is a drag, nil while it is still a click.
    mutating func update(to point: CGPoint) -> CGFloat? {
        if !isDragging {
            guard hypot(point.x - origin.x, point.y - origin.y) >= IslandPlacement.dragThreshold else { return nil }
            isDragging = true
        }
        return point.x - origin.x
    }
}
