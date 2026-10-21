import Foundation

/// Row click: reveal a workspace in the Orca app. The CLI has no "focus workspace" command, so the
/// notch brings one of the workspace's live terminals to the foreground (`terminal switch`, a view
/// change only: no agent, repo or workspace state is touched). Finding that terminal is a read
/// (`terminal list`). `terminal switch` is the single non-read command the notch ever runs; for a workspace
/// on a paired server both commands carry `--environment <id>` (the handle belongs to that server).
public enum OrcaReveal {
    /// Read: live terminals of one workspace.
    static func listArguments(worktreeId: String, environment: String? = nil) -> [String] {
        ["terminal", "list", "--worktree", "id:\(worktreeId)", "--json"] + OrcaCollector.environmentArguments(environment)
    }

    /// The one allowed non-read command.
    /// For a paired server the handle belongs to that server, so the same `--environment` is passed.
    static func switchArguments(handle: String, environment: String? = nil) -> [String] {
        ["terminal", "switch", "--terminal", handle] + OrcaCollector.environmentArguments(environment)
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
    /// Brings the workspace's terminal to the foreground in Orca (for a remote workspace, on the paired
    /// server that owns it). False when it is unknown, has no live terminal, or the CLI failed.
    public func reveal(workspaceKey: String) async -> Bool {
        guard let target = revealTarget(forKey: workspaceKey) else { return false }
        do {
            let list = try await runner.run(arguments: OrcaReveal.listArguments(worktreeId: target.worktreeId, environment: target.environment),
                                            timeout: target.environment == nil ? timeout : environmentTimeout)
            guard let handle = OrcaReveal.pickTerminal(from: list) else { return false }
            _ = try await runner.run(arguments: OrcaReveal.switchArguments(handle: handle, environment: target.environment),
                                     timeout: target.environment == nil ? timeout : environmentTimeout)
            return true
        } catch { return false }
    }

    /// The worktree id and the environment id (nil for this Mac) behind a row key; they stay in the collector.
    func revealTarget(forKey key: String) -> (worktreeId: String, environment: String?)? {
        for w in raw.worktrees {
            guard let id = w.worktreeId, OrcaDerivation.key(for: id) == key else { continue }
            return (w.hostId ?? "local") == "local" ? (id, nil) : nil   // SSH targets: not reachable by the CLI
        }
        for env in raw.environments where env.enabled {
            for w in env.worktrees {
                guard let id = w.worktreeId, OrcaDerivation.key(for: id, hostId: env.host.id) == key else { continue }
                return (id, env.host.id)
            }
        }
        return nil
    }
}
