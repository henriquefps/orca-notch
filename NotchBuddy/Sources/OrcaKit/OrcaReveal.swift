import Foundation

/// Row click: reveal a workspace in the Orca app. The CLI has no "focus workspace" command, so the
/// notch brings one of the workspace's live terminals to the foreground (`terminal switch`, a view
/// change only: no agent, repo or workspace state is touched). Finding that terminal is a read
/// (`terminal list`). `terminal switch` is the single non-read command the notch ever runs.
public enum OrcaReveal {
    /// Read: live terminals of one workspace.
    static func listArguments(worktreeId: String) -> [String] {
        ["terminal", "list", "--worktree", "id:\(worktreeId)", "--json"]
    }

    /// The one allowed non-read command.
    static func switchArguments(handle: String) -> [String] {
        ["terminal", "switch", "--terminal", handle]
    }

    /// Handle to bring forward: a connected terminal running an agent first, else any connected one.
    static func pickTerminal(from data: Data) -> String? {
        struct Envelope: Decodable {
            var result: Result?
            struct Result: Decodable { var terminals: [Terminal]? }
            struct Terminal: Decodable { var handle: String?; var connected: Bool?; var agentIdentity: String? }
        }
        guard let terminals = (try? JSONDecoder().decode(Envelope.self, from: data))?.result?.terminals else { return nil }
        let live = terminals.filter { $0.connected != false && ($0.handle?.isEmpty == false) }
        return (live.first(where: { $0.agentIdentity != nil }) ?? live.first)?.handle
    }
}

extension OrcaCollector {
    /// Brings the workspace's terminal to the foreground in Orca. False when it is unknown, remote,
    /// has no live terminal, or the CLI failed.
    public func reveal(workspaceKey: String) async -> Bool {
        guard let id = raw.worktrees.compactMap(\.worktreeId).first(where: { OrcaDerivation.key(for: $0) == workspaceKey }),
              raw.worktrees.first(where: { $0.worktreeId == id })?.hostId.map({ $0 == "local" }) ?? true else { return false }
        do {
            let list = try await runner.run(arguments: OrcaReveal.listArguments(worktreeId: id), timeout: timeout)
            guard let handle = OrcaReveal.pickTerminal(from: list) else { return false }
            _ = try await runner.run(arguments: OrcaReveal.switchArguments(handle: handle), timeout: timeout)
            return true
        } catch { return false }
    }
}
