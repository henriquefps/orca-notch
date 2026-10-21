import Foundation

/// Output shapes of `orca ... --environment <name> --json`, sanitized from real CachyOS (Linux) and Winboat
/// (Windows) captures: ids, names, paths and prompts replaced; the fields the notch must never keep
/// (endpoints, device ids, prompts, absolute paths) are left in on purpose, to prove they are dropped.
enum RemoteFixtures {
    static let cachyId = "env-cachy-0001"
    static let winboatId = "env-winboat-0002"

    static let environmentList = #"""
    {"id":"fx","ok":true,"result":{"environments":[
     {"id":"env-cachy-0001","name":"CachyOS","createdAt":1,"updatedAt":2,"pairingRevision":1,
      "pairedDeviceId":"DEVICE-ID-DO-NOT-LEAK","lastUsedAt":2,"runtimeId":"RUNTIME-ID-DO-NOT-LEAK",
      "endpoints":[{"id":"ws-1","kind":"websocket","label":"WebSocket","endpoint":"ws://203.0.113.7:6768/TOKEN-DO-NOT-LEAK"}],
      "preferredEndpointId":"ws-1"},
     {"id":"env-winboat-0002","name":"Winboat","createdAt":1,"updatedAt":2,"pairingRevision":1,
      "pairedDeviceId":"DEVICE-ID-DO-NOT-LEAK","lastUsedAt":2,"runtimeId":"RUNTIME-ID-DO-NOT-LEAK",
      "endpoints":[{"id":"ws-2","kind":"websocket","label":"WebSocket","endpoint":"ws://203.0.113.8:6768/orca://pair?code=PAIRING-CODE-DO-NOT-LEAK"}],
      "preferredEndpointId":"ws-2"}
    ]},"_meta":{"runtimeId":"local"}}
    """#

    /// One agent of a remote worktree. `since` is epoch ms.
    struct Agent { var state: String; var since: Double }

    static let nowMs: Double = 1_792_610_700_000

    static func worktree(id: String, name: String, path: String, agents: [Agent], unread: Bool = false,
                         activityMsAgo: Double = 60_000, hostId: String = "local") -> String {
        let list = agents.enumerated().map { i, a in
            """
            {"paneKey":"pane:\(i)","parentPaneKey":null,"state":"\(a.state)","agentType":"claude",
             "prompt":"SECRET-PROMPT-DO-NOT-LEAK","toolInput":"SECRET-TOOLINPUT-DO-NOT-LEAK","toolName":"Bash",
             "lastAssistantMessage":null,"stateStartedAt":\(a.since),"updatedAt":\(a.since)}
            """
        }.joined(separator: ",")
        return """
        {"workspaceKind":"git","worktreeId":"\(id)","repoId":"repo-x","hostId":"\(hostId)","repo":"sample-repo",
         "path":"\(path)","branch":"refs/heads/\(name)","isArchived":false,"displayName":"\(name)",
         "workspaceStatus":"in-progress","lastActivityAt":\(nowMs - activityMsAgo),"unread":\(unread),
         "liveTerminalCount":\(agents.isEmpty ? 0 : 1),"lastOutputAt":null,"status":"\(agents.isEmpty ? "inactive" : "active")",
         "terminalVerdict":"\(agents.isEmpty ? "none" : "live")","agents":[\(list)]}
        """
    }

    static func ps(_ worktrees: [String]) -> String {
        #"{"id":"fx","ok":true,"result":{"hostScope":{"hostIds":["local"],"omittedHostIds":[]},"totalCount":\#(worktrees.count),"truncated":false,"worktrees":["#
            + worktrees.joined(separator: ",") + #"]},"_meta":{"runtimeId":"RUNTIME-ID-DO-NOT-LEAK"}}"#
    }

    // CachyOS (Linux): one agent running, one done today, one idle workspace without agents.
    static let cachyPs = ps([
        worktree(id: "repo-x::/home/redacted/orca/a", name: "cachy-a", path: "/home/redacted/orca/a",
                 agents: [Agent(state: "working", since: nowMs - 120_000)]),
        worktree(id: "repo-x::/home/redacted/orca/b", name: "cachy-b", path: "/home/redacted/orca/b",
                 agents: [Agent(state: "done", since: nowMs - 3_600_000)], activityMsAgo: 3_600_000),
        worktree(id: "repo-x::/home/redacted/orca/c", name: "cachy-c", path: "/home/redacted/orca/c", agents: [],
                 activityMsAgo: 90 * 86_400_000),
    ])

    // Winboat (Windows paths): one workspace with a running and a waiting agent, one idle.
    static let winboatPs = ps([
        worktree(id: "repo-x::C:/Users/redacted/work/w1", name: "winboat-1", path: "C:/Users/redacted/work/w1",
                 agents: [Agent(state: "working", since: nowMs - 30_000), Agent(state: "waiting", since: nowMs - 20_000)]),
        worktree(id: "repo-x::C:/Users/redacted/work/w2", name: "winboat-2", path: "C:/Users/redacted/work/w2", agents: [],
                 activityMsAgo: 90 * 86_400_000),
    ])

    static let emptyWorkers = #"{"id":"fx","ok":true,"result":{"workers":[],"page":{"hasMore":false,"nextCursor":null}}}"#
}
