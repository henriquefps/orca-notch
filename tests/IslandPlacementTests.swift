import Foundation

@main
enum IslandPlacementTests {
    static func main() {
        let minX: CGFloat = 0, maxX: CGFloat = 1512, closed: CGFloat = 240, open: CGFloat = 640

        // Default position: the middle of the screen (the notch on a notched Mac).
        precondition(IslandPlacement.defaultCenterX(screenMinX: minX, screenMaxX: maxX) == 756)
        precondition(IslandPlacement.centerX(storedOffset: nil, islandWidth: closed, screenMinX: minX, screenMaxX: maxX) == 756)
        // A second screen to the right of the first: middle of its own frame.
        precondition(IslandPlacement.defaultCenterX(screenMinX: 1512, screenMaxX: 1512 + 1920) == 1512 + 960)

        // Clamping keeps the whole island inside the screen with the margin.
        let margin = IslandPlacement.screenMargin
        precondition(IslandPlacement.clampedCenterX(-500, islandWidth: closed, screenMinX: minX, screenMaxX: maxX) == margin + closed / 2)
        precondition(IslandPlacement.clampedCenterX(9999, islandWidth: closed, screenMinX: minX, screenMaxX: maxX) == maxX - margin - closed / 2)
        precondition(IslandPlacement.clampedCenterX(400, islandWidth: closed, screenMinX: minX, screenMaxX: maxX) == 400)
        // Offset screens clamp inside their own frame.
        precondition(IslandPlacement.clampedCenterX(0, islandWidth: closed, screenMinX: 1512, screenMaxX: 3432) == 1512 + margin + closed / 2)
        // The open island is wider, so it is pushed further from the edge than the closed one.
        precondition(IslandPlacement.centerX(storedOffset: -700, islandWidth: open, screenMinX: minX, screenMaxX: maxX) == margin + open / 2)
        precondition(IslandPlacement.centerX(storedOffset: -700, islandWidth: closed, screenMinX: minX, screenMaxX: maxX) == margin + closed / 2)
        // Open island anchored at the dragged position when it fits.
        precondition(IslandPlacement.centerX(storedOffset: -100, islandWidth: open, screenMinX: minX, screenMaxX: maxX) == 656)
        // A screen too narrow for the island centers it.
        precondition(IslandPlacement.clampedCenterX(10, islandWidth: 700, screenMinX: 0, screenMaxX: 600) == 300)
        // A stored offset survives a resolution change: it is relative to the screen's middle, then clamped.
        precondition(IslandPlacement.centerX(storedOffset: -600, islandWidth: closed, screenMinX: 0, screenMaxX: 1000) == margin + closed / 2)
        precondition(IslandPlacement.offset(forCenterX: 656, screenMinX: minX, screenMaxX: maxX) == -100)

        // Persistence per display.
        let suite = "orca-notch-placement-tests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = IslandPositionStore(defaults: defaults)
        precondition(store.offset(for: "A") == nil && store.offset(for: nil) == nil)
        store.setOffset(-300, for: "A")
        store.setOffset(250, for: "B")
        precondition(store.offset(for: "A") == -300 && store.offset(for: "B") == 250)
        precondition(IslandPositionStore(defaults: defaults).offset(for: "A") == -300)   // survives a relaunch
        store.setOffset(-120, for: "A")
        precondition(store.offset(for: "A") == -120 && store.offset(for: "B") == 250)
        store.reset(for: "A")
        precondition(store.offset(for: "A") == nil && store.offset(for: "B") == 250)
        store.setOffset(10, for: nil)                       // no display identifier: nothing stored
        precondition(defaults.dictionary(forKey: IslandPositionStore.defaultsKey)?.count == 1)

        // Click versus drag: a 4 pt threshold, then it stays a drag.
        precondition(IslandPlacement.dragThreshold == 4)
        var click = IslandDragTracker(origin: CGPoint(x: 100, y: 5))
        precondition(click.update(to: CGPoint(x: 100, y: 5)) == nil)
        precondition(click.update(to: CGPoint(x: 102, y: 6)) == nil)       // hover jitter and a plain click
        precondition(click.update(to: CGPoint(x: 103.9, y: 5)) == nil)
        precondition(!click.isDragging)
        var drag = IslandDragTracker(origin: CGPoint(x: 100, y: 5))
        precondition(drag.update(to: CGPoint(x: 104, y: 5)) == 4)          // threshold reached
        precondition(drag.isDragging)
        precondition(drag.update(to: CGPoint(x: 101, y: 5)) == 1)          // comes back: still a drag
        precondition(drag.update(to: CGPoint(x: 60, y: 5)) == -40)
        var diagonal = IslandDragTracker(origin: CGPoint(x: 0, y: 0))
        precondition(diagonal.update(to: CGPoint(x: 0, y: 4)) == 0 && diagonal.isDragging)   // vertical travel counts, x stays locked

        print("Island placement: all cases passed")
    }
}
