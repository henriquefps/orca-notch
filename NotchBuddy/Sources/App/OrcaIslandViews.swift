import SwiftUI
import AppKit

// Orca data in the island: the counters of the closed island and the open workspace list.
// Placeholder styling, consistent with the existing cards. Read-only except the row click, which only
// brings the workspace's terminal forward in Orca (OrcaReveal).

private enum OrcaColors {
    static let running = Color(hex: "#3B9EFF")
    static let finished = Color(hex: "#34D399")
    static let alert = Color(hex: "#F5A524")
    static let failed = Color(hex: "#F4505E")
    static let review = Color(hex: "#A78BFA")
    static let idle = Color(hex: "#6B7079")
    static let text = Color(hex: "#F5F6F8")
    static let secondary = Color(hex: "#8E939C")
}

// MARK: - Icons (the Orca sidebar's: spinner, check-circle, bell)

/// Rotating arc. The rotation is a Core Animation animation, which the render server runs on its own:
/// a SwiftUI `repeatForever` or a TimelineView re-renders the whole island on every frame (measured:
/// the main cost of an open island). Only animates while the view is on screen and active.
struct OrcaSpinner: View {
    var size: CGFloat = 10
    var color: Color = OrcaColors.running
    @Environment(\.islandViewActive) private var active

    var body: some View {
        SpinnerLayerView(color: NSColor(color), lineWidth: max(1.2, size / 8), spinning: active)
            .frame(width: size, height: size)
    }
}

private struct SpinnerLayerView: NSViewRepresentable {
    let color: NSColor
    let lineWidth: CGFloat
    let spinning: Bool

    func makeNSView(context: Context) -> SpinnerNSView { SpinnerNSView() }

    func updateNSView(_ view: SpinnerNSView, context: Context) {
        view.configure(color: color, lineWidth: lineWidth, spinning: spinning)
    }

    final class SpinnerNSView: NSView {
        private let arc = CAShapeLayer()
        private var spinning = false
        private static let key = "spin"

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.addSublayer(arc)
            arc.fillColor = nil
            arc.lineCap = .round
            arc.strokeStart = 0.12
            arc.strokeEnd = 0.82
        }

        required init?(coder: NSCoder) { fatalError() }

        func configure(color: NSColor, lineWidth: CGFloat, spinning: Bool) {
            arc.strokeColor = color.cgColor
            arc.lineWidth = lineWidth
            self.spinning = spinning
            syncAnimation()
        }

        override func layout() {
            super.layout()
            // A zero-anchored layer would rotate around its corner: centre it on the view.
            let inset = arc.lineWidth / 2
            let rect = bounds.insetBy(dx: inset, dy: inset)
            arc.bounds = bounds
            arc.position = CGPoint(x: bounds.midX, y: bounds.midY)
            arc.path = CGPath(ellipseIn: rect, transform: nil)
            syncAnimation()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            syncAnimation()   // Core Animation drops animations when a layer leaves its window
        }

        private func syncAnimation() {
            let running = arc.animation(forKey: Self.key) != nil
            guard spinning && window != nil else {
                if running { arc.removeAnimation(forKey: Self.key) }
                return
            }
            guard !running else { return }
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi          // clockwise
            spin.duration = 0.9
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            arc.add(spin, forKey: Self.key)
        }
    }
}

struct OrcaStatusIcon: View {
    let status: OrcaAgentStatus
    var size: CGFloat = 10

    var body: some View {
        switch status {
        case .running:  OrcaSpinner(size: size)
        case .finished: Image(systemName: "checkmark.circle").font(.system(size: size, weight: .semibold)).foregroundColor(OrcaColors.finished)
        case .alert:    Image(systemName: "bell.fill").font(.system(size: size, weight: .semibold)).foregroundColor(OrcaColors.alert)
        case .idle:     Image(systemName: "circle.dotted").font(.system(size: size)).foregroundColor(OrcaColors.idle)
        }
    }
}

struct OrcaWorkspaceStateIcon: View {
    let state: OrcaWorkspaceState
    var size: CGFloat = 13

    var body: some View {
        Group {
            switch state {
            case .running:   OrcaSpinner(size: size)
            case .done:      OrcaStatusIcon(status: .finished, size: size)
            case .attention: OrcaStatusIcon(status: .alert, size: size)
            case .failed:    Image(systemName: "xmark.circle.fill").font(.system(size: size, weight: .semibold)).foregroundColor(OrcaColors.failed)
            case .review:    Image(systemName: "eye.circle").font(.system(size: size, weight: .semibold)).foregroundColor(OrcaColors.review)
            case .idle:      OrcaStatusIcon(status: .idle, size: size)
            }
        }
        .frame(width: size + 2, height: size + 2)
    }
}

// MARK: - Closed island: three agent counters

struct OrcaCounterStrip: View {
    let counts: OrcaAgentCounts
    var iconSize: CGFloat = 20

    var body: some View {
        HStack(spacing: 10) {
            if counts.running > 0 { counter(.running, counts.running) }
            if counts.finished > 0 { counter(.finished, counts.finished) }
            if counts.alert > 0 { counter(.alert, counts.alert) }
        }
        .fixedSize()
        .animation(.easeInOut(duration: 0.2), value: counts)
    }

    private func counter(_ status: OrcaAgentStatus, _ n: Int) -> some View {
        HStack(spacing: 3) {
            OrcaStatusIcon(status: status, size: iconSize)
            Text(n > 99 ? "99+" : "\(n)")
                .font(.system(size: iconSize * 0.8, weight: .semibold).monospacedDigit())
                .foregroundColor(OrcaColors.text)

        }
    }
}

// MARK: - Open island: flat workspace list + usage footer

struct OrcaWorkspaceListView: View {
    @ObservedObject var state: AppState

    /// Workspaces worth a row: anything with an agent or a non-idle state. Already ordered by the
    /// derivation (failed, needs you, running, review, done; then most recent).
    private var rows: [OrcaWorkspace] {
        state.orca.workspaces.filter { $0.state != .idle || !$0.agents.isEmpty }
    }

    var body: some View {
        ZStack {
            CardBackground(wash: nil)
            VStack(spacing: 0) {
                if rows.isEmpty {
                    emptyState
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { OrcaWorkspaceRow(workspace: $0) }
                        }
                    }
                }
                OrcaUsageFooter(usage: state.orca.usage, offlineHosts: state.orca.hosts.filter(\.isOffline).map(\.host.name))
            }
            .padding(.leading, 108)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Spacer()
            Text(state.orca.orca.ok ? "Nothing running in Orca." : "Orca is not reachable.")
                .font(.system(size: 13, weight: .semibold))
            Text(state.orca.orca.ok ? "Agents and workspaces show up here." : "Open Orca and this list fills in.")
                .font(.system(size: 11))
                .foregroundColor(OrcaColors.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct OrcaWorkspaceRow: View {
    let workspace: OrcaWorkspace

    var body: some View {
        HStack(spacing: 8) {
            OrcaWorkspaceStateIcon(state: workspace.state)
            VStack(alignment: .leading, spacing: 1) {
                Text(workspace.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(OrcaColors.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(OrcaColors.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            if workspace.hostId != "local" {
                Text(workspace.host)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(OrcaColors.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
                    .fixedSize()
            }
            if let pr = workspace.pr, let number = pr.number {
                Text("PR #\(number)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(pr.isOpen ? OrcaColors.finished : OrcaColors.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
                    .fixedSize()
            }
            HStack(spacing: 3) {
                ForEach(Array(workspace.agents.enumerated()), id: \.offset) { _, agent in
                    OrcaStatusIcon(status: agent.status, size: 10)
                }
            }
            .fixedSize()
            // The snapshot no longer republishes while nothing changes: the age ticks on its own.
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Text(ago)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(OrcaColors.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { OrcaIslandBridge.shared.store.reveal(workspaceKey: workspace.key) }
    }

    private var subtitle: String {
        [workspace.repo, workspace.branch].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var ago: String {
        workspace.lastActivityAt.map { OrcaFormatting.ago(since: $0) } ?? ""
    }
}

struct OrcaUsageFooter: View {
    let usage: [OrcaProviderUsage]
    /// Names of the paired servers that could not be reached; their rows are the last good ones.
    var offlineHosts: [String] = []

    var body: some View {
        if !usage.isEmpty || !offlineHosts.isEmpty {
            VStack(spacing: 4) {
                Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(offlineHosts, id: \.self) { name in
                            HStack(spacing: 4) {
                                Image(systemName: "wifi.slash").font(.system(size: 9, weight: .semibold))
                                Text("\(name) offline").font(.system(size: 10, weight: .medium))
                            }
                            .foregroundColor(OrcaColors.alert)
                            .fixedSize()
                        }
                        ForEach(usage) { provider in
                            HStack(spacing: 5) {
                                Text(provider.label)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(OrcaColors.text)
                                window("session", provider.session)
                                window("week", provider.weekly)
                            }
                            .fixedSize()
                        }
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func window(_ name: String, _ w: OrcaUsageWindow?) -> some View {
        if let w {
            let tint: Color = w.pct >= 90 ? OrcaColors.failed : w.pct >= 70 ? OrcaColors.alert : OrcaColors.secondary
            Text("\(name) \(Int(w.pct.rounded()))%\(w.resetText.map { " · resets \($0)" } ?? "")")
                .font(.system(size: 10).monospacedDigit())
                .foregroundColor(tint)
        }
    }
}
