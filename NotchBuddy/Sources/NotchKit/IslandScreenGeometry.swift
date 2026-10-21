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
struct IslandRestingLayout {
    let width: CGFloat
    let height: CGFloat

    /// Each side of the notch in the resting island: the mascot on the left, the Orca counters on the right.
    static let earWidth: CGFloat = 148
    /// Counter icon size: 2x the first version, capped so it fits a short (notchless) bar.
    var counterIconSize: CGFloat { min(20, max(10, height - 6)) }
    var counterCenterX: CGFloat { width - Self.earWidth / 2 }

    var botDiameter: CGFloat { min(20, max(0, height - 6)) }
    var botCenterY: CGFloat { height / 2 }
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
