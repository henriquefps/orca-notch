import Foundation

/// Resting island dimensions, using a physical notch only when the screen has one.
struct IslandScreenGeometry {
    static let fallbackNotchWidth: CGFloat = 184
    private static let noNotchWidth: CGFloat = 80
    private static let noNotchHeight: CGFloat = 24

    let hasNotch: Bool
    let width: CGFloat
    let height: CGFloat

    init(screenWidth: CGFloat, safeAreaTop: CGFloat,
         auxiliaryLeftWidth: CGFloat?, auxiliaryRightWidth: CGFloat?,
         menuBarHeight: CGFloat) {
        hasNotch = safeAreaTop > 0
        if hasNotch {
            if let left = auxiliaryLeftWidth, let right = auxiliaryRightWidth {
                let measuredWidth = screenWidth - left - right
                width = measuredWidth > 0 && measuredWidth < screenWidth
                    ? measuredWidth : Self.fallbackNotchWidth
            } else {
                width = Self.fallbackNotchWidth
            }
            height = safeAreaTop
        } else {
            width = Self.noNotchWidth
            height = min(Self.noNotchHeight, menuBarHeight)
        }
    }
}

/// Shared by the compact view and the greeting's collapse destination.
///
/// The closed island is half the width of the first version (`notch + 2 * 148`) and the same height: the ears are
/// cut, the glyphs keep their size. The three Orca counters sit centered as one group; the mascot stays in the
/// left part and is hidden when it does not fit beside them.
struct IslandRestingLayout {
    let width: CGFloat
    let height: CGFloat

    /// Each side of the notch in the first version of the resting island.
    static let fullEarWidth: CGFloat = 148
    /// Closed width is this fraction of the first version's; the height does not change.
    static let closedScale: CGFloat = 0.5

    /// Closed width for a notch (or notchless bar) of `notchWidth`.
    static func closedWidth(notchWidth: CGFloat) -> CGFloat { ((notchWidth + 2 * fullEarWidth) * closedScale).rounded() }
    /// Closed height for a notch (or notchless bar) of `notchHeight`.
    static func closedHeight(notchHeight: CGFloat) -> CGFloat { notchHeight }
    /// Bottom corner radius of the closed island: the usual one, never more than the bar allows.
    static func cornerRadius(height: CGFloat, preferred: CGFloat) -> CGFloat { min(preferred, height / 2) }

    /// Counter icon size: capped so it fits a short (notchless) bar.
    var counterIconSize: CGFloat { min(20, max(10, height - 6)) }
    var counterSpacing: CGFloat { counterIconSize / 2 }
    var counterInnerSpacing: CGFloat { max(2, counterIconSize * 0.15) }
    /// The counters are one group, centered in the island.
    var counterCenterX: CGFloat { width / 2 }

    /// Widest the counter group can get (three counters, two digits each), for the "does the mascot fit" test.
    var counterGroupMaxWidth: CGFloat {
        let digits = counterIconSize * 0.8 * 0.62 * 2
        return 3 * (counterIconSize + counterInnerSpacing + digits) + 2 * counterSpacing
    }

    var botDiameter: CGFloat { min(20, max(0, height - 6)) }
    var botCenterY: CGFloat { height / 2 }
    var botEdgePadding: CGFloat { 6 }
    var botCenterX: CGFloat { botEdgePadding + botDiameter / 2 }
    /// The mascot is drawn in the closed island only if it fits left of the counter group.
    var showsMascot: Bool {
        botDiameter > 0 && botEdgePadding + botDiameter + botEdgePadding <= (width - counterGroupMaxWidth) / 2
    }
    var miniGridScale: CGFloat { min(1, max(0, height - 4) / 28) }
    var miniGridCenterX: CGFloat { width - 40 }
}

// MARK: - Desktop space

/// One y-down space for the whole desktop, like Quartz: x as in AppKit, y measured down
/// from the top of the menu-bar screen. The cursor and the mascot use it, so the gaze
/// stays right whichever screen the island sits on.
enum DesktopSpace {
    static func topDown(_ appKitPoint: CGPoint, desktopTop: CGFloat) -> CGPoint {
        CGPoint(x: appKitPoint.x, y: desktopTop - appKitPoint.y)
    }
}
