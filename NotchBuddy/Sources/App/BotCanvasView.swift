import SwiftUI
import AppKit
import os

/// How often the main mascot redraws. Every frame costs a SwiftUI + Core Animation pass (about 0.35 % CPU
/// per frame per second, whatever the build), so frames are rationed:
///   - 20 fps (the rate `engine.update(dt: 0.05)` assumes; the display's 60 to 120 Hz only burned CPU)
///     for `linger` seconds after the pointer moved or an emote fired;
///   - 10 fps while the mascot works or thinks, 6 fps while it idles, in the open island;
///   - 4 / 2 fps in the closed island, where the mascot sits at the edge of the strip.
/// Each tick asks for the next interval, so the rate follows the pointer and the state without
/// rebuilding the view; `engine.update` gets the real step, so the animation speed does not change.
enum MascotPacing {
    static let activeInterval: TimeInterval = 1.0 / 20.0
    /// Full rate this long after the pointer moved or an emote fired.
    static let linger: TimeInterval = 1.5

    private struct Info { var lastActivity: CFAbsoluteTime = 0; var busy = false; var compact = false }
    private static let info = OSAllocatedUnfairLock(initialState: Info())

    /// Pointer moved, emote fired, state changed.
    static func touch() { info.withLock { $0.lastActivity = CFAbsoluteTimeGetCurrent() } }
    /// The mascot is not idle (working, thinking...).
    static func setBusy(_ busy: Bool) { info.withLock { $0.busy = busy; $0.lastActivity = CFAbsoluteTimeGetCurrent() } }
    static func setCompact(_ compact: Bool) { info.withLock { $0.compact = compact } }

    static func interval(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> TimeInterval {
        let i = info.withLock { $0 }
        if now - i.lastActivity < linger { return activeInterval }
        switch (i.busy, i.compact) {
        case (true, false): return 1.0 / 10
        case (false, false): return 1.0 / 6
        case (true, true): return 1.0 / 4
        case (false, true): return 1.0 / 2
        }
    }
}

struct MascotSchedule: TimelineSchedule {
    var paused = false

    func entries(from start: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(at: start, paused: paused)
    }

    struct Entries: Sequence, IteratorProtocol {
        var at: Date
        var paused: Bool
        func makeIterator() -> Entries { self }
        mutating func next() -> Date? {
            guard !paused else { return nil }
            defer { at = Swift.max(at.addingTimeInterval(MascotPacing.interval()), Date()) }
            return at
        }
    }
}

/// SwiftUI wrapper: TimelineView drives a Canvas that calls MascotEngine.draw().
struct BotCanvasView: View {
    @ObservedObject var state: AppState
    var particleOverhang: CGFloat = 0
    /// Not drawn while true.
    var paused: Bool = false

    // One engine per view instance (main bot)
    @StateObject private var engine = MascotEngine()

    var body: some View {
        TimelineView(MascotSchedule(paused: state.mode == .hidden || paused)) { timeline in
            // The Canvas must capture the frame's date: a closure that doesn't change from
            // one tick to the next is not redrawn.
            let frame = timeline.date
            Canvas { context, size in
                _ = frame
                let look = lookXY(state: state)
                engine.lookX = look.x
                engine.lookY = look.y
                if state.showingPlanDetail {
                    let hex = state.planDetailIsCodex
                        ? CodexPlanGauge.color(state.codexPlanUsage)
                        : ClaudePlanGauge.color(for: state.claudePlanUsage.flatMap { ClaudePlanGauge.dominantPct($0) })
                    engine.bodyColor = cgColorFromHex(hex)
                } else {
                    // Integration pills have a fixed brand colour; agents use the state's colour.
                    engine.bodyColor = (state.focusTask?.isIntegration == true)
                        ? cgColorFromHex(state.focusTask!.color)
                        : nil
                }
                engine.update(dt: MascotPacing.interval())
                engine.draw(context: context, size: size)
            }
        }
        .onChange(of: state.mode) { _, mode in
            MascotPacing.setCompact(mode != .expanded)
        }
        .onChange(of: state.effectiveState) { _, newState in
            MascotPacing.setBusy(newState != .idle)
            engine.setState(newState)
        }
        .onReceive(NotificationCenter.default.publisher(for: .triggerEmote)) { notif in
            MascotPacing.touch()
            if let emote = notif.object as? BotEmote { engine.triggerEmote(emote) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .triggerSlap)) { _ in
            MascotPacing.touch()
            engine.slap()
        }
        .onReceive(NotificationCenter.default.publisher(for: .botBlink)) { _ in
            MascotPacing.touch()
            engine.blink()
        }
        .onAppear {
            MascotPacing.setCompact(state.mode != .expanded)
            MascotPacing.setBusy(state.effectiveState != .idle)
            engine.setState(state.effectiveState, force: true)
        }
    }

    /// Where the mascot looks (the pointer), both axes at once: the island geometry and the
    /// screen are looked up once per frame instead of twice each.
    private func lookXY(state: AppState) -> (x: CGFloat, y: CGFloat) {
        let (islandW, islandH) = islandSize(mode: state.mode, view: state.view,
                                             nw: state.notchWidth, nh: state.notchHeight)
        let screen = IslandWindowController.islandScreen().frame
        let desktopTop = IslandWindowController.desktopTop
        // The pointer read now, not from the island poll (which slows down far from it).
        let mouse = DesktopSpace.topDown(NSEvent.mouseLocation, desktopTop: desktopTop)
        func botPoint(islandH: CGFloat) -> CGPoint {
            let (botCx, botCy, _, _) = botPosition(mode: state.mode, view: state.view,
                                                    islandW: islandW, islandH: islandH)
            return DesktopSpace.topDown(CGPoint(x: (IslandWindowController.currentCenterX ?? screen.midX) - islandW / 2 + botCx,
                                                y: screen.maxY - botCy),
                                        desktopTop: desktopTop)
        }
        let botX = botPoint(islandH: islandH)
        // The chat view grows with the conversation: vertical look uses its real height.
        let actualH: CGFloat = (state.mode == .expanded && state.view == .prompt)
            ? min(300, 240 + CGFloat(state.chatHistory.count) * 40)
            : islandH
        let botY = actualH == islandH ? botX : botPoint(islandH: actualH)
        return (tanh((mouse.x - botX.x) / 260),
                -tanh((mouse.y - botY.y) / 200))
    }
}

/// Mini mascot canvas (for agent pills/column)
struct MiniBotCanvasView: View {
    let task: AgentTask
    @StateObject private var engine: MascotEngine

    init(task: AgentTask) {
        self.task = task
        _engine = StateObject(wrappedValue: {
            let e = MascotEngine()
            e.isMini = true
            e.bodyColor = cgColorFromHex(task.color)
            return e
        }())
    }

    @Environment(\.islandViewActive) private var viewActive

    var body: some View {
        // Paused in island views that are not shown.
        TimelineView(.animation(minimumInterval: MascotPacing.activeInterval, paused: !viewActive)) { timeline in
            let frame = timeline.date   // redraw on every tick
            Canvas { context, size in
                _ = frame
                engine.update(dt: 0.05)
                engine.draw(context: context, size: size)
            }
        }
        .onChange(of: task.state) { _, newState in
            engine.setState(newState)
        }
        // A colour picked in Settings has to reach a mascot that is already on screen.
        .onChange(of: task.color) { _, newColor in
            engine.bodyColor = cgColorFromHex(newColor)
        }
        .onAppear {
            engine.setState(task.state, force: true)
        }
    }
}
