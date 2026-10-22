import Foundation

@main
enum IslandScreenGeometryTests {
    static func main() {
        // Regression: absent auxiliary areas must never mean "screen-wide notch".
        for screenWidth: CGFloat in [1080, 1920, 2560, 3840] {
            let geometry = IslandScreenGeometry(
                screenWidth: screenWidth, safeAreaTop: 0,
                auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, menuBarHeight: 30
            )
            precondition(!geometry.hasNotch)
            precondition(geometry.width == 80)
            precondition(geometry.height == 24)
        }

        // A shorter menu bar must also contain the resting island.
        let shortMenuBar = IslandScreenGeometry(
            screenWidth: 1920, safeAreaTop: 0,
            auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, menuBarHeight: 22
        )
        precondition(shortMenuBar.height == 22)

        // Real MacBook notch measurements retain their physical dimensions.
        let macBook = IslandScreenGeometry(
            screenWidth: 1512, safeAreaTop: 32,
            auxiliaryLeftWidth: 660, auxiliaryRightWidth: 660, menuBarHeight: 32
        )
        precondition(macBook.hasNotch)
        precondition(macBook.width == 192 && macBook.height == 32)

        // Incomplete or invalid measurements use the notch fallback, not the screen.
        for auxiliaryWidth: CGFloat? in [nil, 0, 1000] {
            let geometry = IslandScreenGeometry(
                screenWidth: 1512, safeAreaTop: 32,
                auxiliaryLeftWidth: auxiliaryWidth, auxiliaryRightWidth: auxiliaryWidth,
                menuBarHeight: 32
            )
            precondition(geometry.width == 184 && geometry.height == 32)
        }
        // Closed island: half the first version's width (notch + 2 * 148), same height.
        precondition(IslandRestingLayout.closedWidth(notchWidth: 184) == 240)   // notched: was 480
        precondition(IslandRestingLayout.closedHeight(notchHeight: 32) == 32)   // unchanged
        precondition(IslandRestingLayout.closedWidth(notchWidth: 80) == 188)    // notchless: was 376
        precondition(IslandRestingLayout.closedHeight(notchHeight: 24) == 24)   // unchanged
        precondition(IslandRestingLayout.cornerRadius(height: 24, preferred: 14) == 12)
        precondition(IslandRestingLayout.cornerRadius(height: 40, preferred: 14) == 14)

        // Counters are one centered group, glyphs keep their size and stay inside the bar.
        for (width, height): (CGFloat, CGFloat) in [(188, 24), (240, 32), (188, 22), (240, 38)] {
            let compact = IslandRestingLayout(width: width, height: height)
            precondition(compact.counterCenterX == width / 2)
            precondition(compact.counterIconSize == min(20, max(10, height - 6)))
            precondition(compact.counterGroupMaxWidth < width)
            precondition(compact.botCenterY == height / 2)
            precondition(compact.botDiameter == min(20, height - 6))
            precondition(compact.botCenterY - compact.botDiameter / 2 >= 3)
            precondition(compact.botCenterY + compact.botDiameter / 2 <= height - 3)
        }
        // The mascot is shown only if it fits left of the counter group: on a notch yes, on the narrow notchless bar no.
        let notched = IslandRestingLayout(width: 240, height: 32)
        precondition(notched.showsMascot)
        precondition(notched.botCenterX + notched.botDiameter / 2 < 120 - notched.counterGroupMaxWidth / 2)
        precondition(!IslandRestingLayout(width: 188, height: 24).showsMascot)
        precondition(!IslandRestingLayout(width: 110, height: 32).showsMascot)
        print("Island screen geometry and resting layout: all cases passed")
    }
}
