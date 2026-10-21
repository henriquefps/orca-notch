import XCTest
@testable import OrcaKit

final class OrcaEnvironmentsTests: XCTestCase {
    private let now = TestClock.now
    private var cal: Calendar { TestClock.utc }

    private func merged(_ runner: FakeRunner, full: Bool = true) async -> (OrcaCollector, OrcaSnapshot) {
        let c = OrcaCollector(runner: runner)
        _ = await c.collect(now: now, calendar: cal)
        let s = await c.pollEnvironments(full: full, now: now, calendar: cal)
        return (c, s)
    }

    func testMultiHostMergeTagsEveryWorkspaceAndAgentWithItsHost() async {
        let (_, s) = await merged(.withEnvironments())
        let local = s.workspaces.filter { $0.hostId == "local" }
        XCTAssertFalse(local.isEmpty)
        XCTAssertTrue(local.allSatisfy { $0.host == "Local" && $0.agents.allSatisfy { $0.host == "Local" } })
        let cachy = s.workspaces.filter { $0.host == "CachyOS" }
        let winboat = s.workspaces.filter { $0.host == "Winboat" }
        XCTAssertEqual(cachy.map(\.name).sorted(), ["cachy-a", "cachy-b", "cachy-c"])
        XCTAssertEqual(winboat.map(\.name).sorted(), ["winboat-1", "winboat-2"])
        XCTAssertTrue((cachy + winboat).allSatisfy { $0.isRemote })
        XCTAssertEqual(winboat.first { $0.name == "winboat-1" }?.agents.map(\.host), ["Winboat", "Winboat"])
        XCTAssertEqual(s.hosts.map(\.host.name), ["CachyOS", "Winboat"])
        XCTAssertTrue(s.hosts.allSatisfy { $0.ok && !$0.isOffline })
        XCTAssertEqual(Set(s.workspaces.map(\.key)).count, s.workspaces.count)   // unique keys
    }

    func testFlatUrgencySortAcrossHosts() async {
        let (_, s) = await merged(.withEnvironments())
        let priorities = s.workspaces.map(\.state.priority)
        XCTAssertEqual(priorities, priorities.sorted())
        // Winboat's waiting agent needs the user: it outranks the running CachyOS workspace.
        let idx = { (n: String) in s.workspaces.firstIndex { $0.name == n }! }
        XCTAssertLessThan(idx("winboat-1"), idx("cachy-a"))
    }

    func testCountersSumAgentsAcrossAllHosts() async {
        let local = await OrcaCollector(runner: FakeRunner.standard()).collect(now: now, calendar: cal).agentCounts
        let (_, all) = await merged(.withEnvironments())
        // CachyOS: 1 running + 1 done today. Winboat: 1 running + 1 waiting (bell).
        XCTAssertEqual(all.agentCounts, OrcaAgentCounts(running: local.running + 2, finished: local.finished + 1, alert: local.alert + 1))
        XCTAssertEqual(all.counts.runningAgents, local.running + 2)
        XCTAssertGreaterThanOrEqual(all.counts.remote, 5)   // the five paired-server workspaces (plus any SSH ones)
    }

    func testOneHostFailingKeepsTheOthersAndItsOwnLastGoodRows() async {
        let runner = FakeRunner.withEnvironments()
        let (c, good) = await merged(runner)
        runner.fail("worktree ps --json --environment \(RemoteFixtures.winboatId)", .timeout)
        let later = now.addingTimeInterval(20)
        let bad = await c.pollEnvironments(full: false, now: later, calendar: cal)
        let winboat = bad.hosts.first { $0.host.name == "Winboat" }!
        XCTAssertFalse(winboat.ok)
        XCTAssertTrue(winboat.isOffline)
        XCTAssertEqual(winboat.error, "orca timed out")
        XCTAssertEqual(winboat.lastSuccessAt, Int(now.timeIntervalSince1970))
        XCTAssertTrue(bad.hosts.first { $0.host.name == "CachyOS" }!.ok)
        XCTAssertEqual(bad.workspaces.map(\.key), good.workspaces.map(\.key))   // last good rows retained
        XCTAssertEqual(bad.agentCounts, good.agentCounts)
    }

    func testHostThatNeverAnsweredHasNoRowsAndLocalIsUntouched() async {
        let runner = FakeRunner.withEnvironments()
        runner.fail("worktree ps --json --environment \(RemoteFixtures.cachyId)", .nonZeroExit(1, "connect to /Users/someone/x refused"))
        let (_, s) = await merged(runner)
        XCTAssertTrue(s.hosts.first { $0.host.name == "CachyOS" }!.isOffline)
        XCTAssertFalse(s.hosts.first { $0.host.name == "CachyOS" }!.error!.contains("/Users"))
        XCTAssertTrue(s.workspaces.filter { $0.host == "CachyOS" }.isEmpty)
        XCTAssertFalse(s.workspaces.filter { $0.host == "Winboat" }.isEmpty)
        XCTAssertFalse(s.workspaces.filter { $0.hostId == "local" }.isEmpty)
    }

    func testEnvironmentListFailingKeepsTheKnownHosts() async {
        let runner = FakeRunner.withEnvironments()
        let (c, _) = await merged(runner)
        runner.fail("environment list --json", .timeout)
        let s = await c.pollEnvironments(full: false, now: now.addingTimeInterval(61), calendar: cal)
        XCTAssertEqual(s.hosts.map(\.host.name), ["CachyOS", "Winboat"])
    }

    func testDedupesWorkspaceTheLocalListAlsoReportsForAPairedServer() async {
        let runner = FakeRunner.withEnvironments()
        // A future `worktree ps` that annotates paired-server rows: host=runtime:<environment id>.
        let dup = RemoteFixtures.worktree(id: "repo-x::C:/Users/redacted/work/w1", name: "winboat-1", path: "C:/Users/redacted/work/w1",
                                          agents: [.init(state: "working", since: RemoteFixtures.nowMs - 30_000)],
                                          hostId: "runtime:\(RemoteFixtures.winboatId)")
        runner.set("worktree ps --json", RemoteFixtures.ps([dup]))
        let local0Running = 0   // the stubbed local list holds only the duplicate (1 running); added below
        let (_, s) = await merged(runner)
        XCTAssertEqual(s.workspaces.filter { $0.name == "winboat-1" }.count, 1)
        XCTAssertEqual(s.workspaces.first { $0.name == "winboat-1" }?.host, "Winboat")
        XCTAssertEqual(s.agentCounts.running, local0Running + 2)   // CachyOS 1 + Winboat 1, the duplicate counted once
    }

    func testSameWorktreeIdOnTwoHostsKeepsBothRows() async {
        let runner = FakeRunner.withEnvironments()
        let same = RemoteFixtures.ps([RemoteFixtures.worktree(id: "repo-x::/shared", name: "same", path: "/shared",
                                                              agents: [.init(state: "working", since: RemoteFixtures.nowMs)])])
        runner.set("worktree ps --json --environment \(RemoteFixtures.cachyId)", same)
        runner.set("worktree ps --json --environment \(RemoteFixtures.winboatId)", same)
        let (_, s) = await merged(runner)
        XCTAssertEqual(s.workspaces.filter { $0.name == "same" }.map(\.host).sorted(), ["CachyOS", "Winboat"])
        XCTAssertEqual(Set(s.workspaces.filter { $0.name == "same" }.map(\.key)).count, 2)
    }

    func testCadenceFastCycleOnlyWorktreePsAndDiscoveryOncePerMinute() async {
        let runner = FakeRunner.withEnvironments()
        let c = OrcaCollector(runner: runner)
        _ = await c.pollEnvironments(full: false, now: now, calendar: cal)
        XCTAssertEqual(runner.callCount("environment list"), 1)
        XCTAssertEqual(runner.callCount("worktree ps"), 2)
        XCTAssertEqual(runner.callCount("orchestration worker-list"), 0)
        XCTAssertTrue(runner.calls.allSatisfy { $0.contains("--json") })
        _ = await c.pollEnvironments(full: true, now: now.addingTimeInterval(2.5), calendar: cal)
        XCTAssertEqual(runner.callCount("environment list"), 1)            // not re-discovered
        XCTAssertEqual(runner.callCount("worktree ps"), 4)
        XCTAssertEqual(runner.callCount("orchestration worker-list"), 2)    // full cycle adds workers
        _ = await c.pollEnvironments(full: false, now: now.addingTimeInterval(61), calendar: cal)
        XCTAssertEqual(runner.callCount("environment list"), 2)
        XCTAssertEqual(runner.callCount("account list"), 0)                 // accounts stay local-only
        XCTAssertEqual(runner.callCount("status"), 0)
    }

    func testUnreachableHostIsRetriedNoMoreOftenThanAFullCycle() async {
        let runner = FakeRunner.withEnvironments()
        runner.fail("worktree ps --json --environment \(RemoteFixtures.winboatId)", .timeout)
        let c = OrcaCollector(runner: runner)
        func winboatPolls() -> Int { runner.calls.filter { $0 == ["worktree", "ps", "--json", "--environment", RemoteFixtures.winboatId] }.count }
        _ = await c.pollEnvironments(full: false, now: now, calendar: cal)
        _ = await c.pollEnvironments(full: false, now: now.addingTimeInterval(2.5), calendar: cal)
        _ = await c.pollEnvironments(full: false, now: now.addingTimeInterval(5), calendar: cal)
        XCTAssertEqual(winboatPolls(), 1)
        _ = await c.pollEnvironments(full: false, now: now.addingTimeInterval(15), calendar: cal)
        XCTAssertEqual(winboatPolls(), 2)
    }

    func testDisabledHostsAreNotPolledAndNotShown() async {
        let runner = FakeRunner.withEnvironments()
        let c = OrcaCollector(runner: runner)
        await c.setEnvironmentPolicy(includeAll: true, disabledIds: [RemoteFixtures.winboatId])
        let s = await c.pollEnvironments(full: true, now: now, calendar: cal)
        XCTAssertEqual(runner.callCount("worktree ps --json --environment \(RemoteFixtures.winboatId)"), 0)
        XCTAssertTrue(s.workspaces.filter { $0.host == "Winboat" }.isEmpty)
        XCTAssertEqual(s.hosts.first { $0.host.name == "Winboat" }?.enabled, false)   // still listed for Settings
        XCTAssertFalse(s.hosts.first { $0.host.name == "Winboat" }!.isOffline)

        await c.setEnvironmentPolicy(includeAll: false, disabledIds: [])
        let before = runner.callCount("worktree ps")
        let off = await c.pollEnvironments(full: true, now: now.addingTimeInterval(30), calendar: cal)
        XCTAssertEqual(runner.callCount("worktree ps"), before)
        XCTAssertTrue(off.workspaces.filter { $0.isRemote }.isEmpty)
    }

    func testPrivacyNoEndpointsTokensDeviceIdsPromptsOrPaths() async {
        let (_, s) = await merged(.withEnvironments())
        let dump = String(reflecting: s)
        for secret in ["DEVICE-ID-DO-NOT-LEAK", "RUNTIME-ID-DO-NOT-LEAK", "TOKEN-DO-NOT-LEAK", "PAIRING-CODE-DO-NOT-LEAK",
                       "203.0.113", "ws://", "orca://", "SECRET-PROMPT-DO-NOT-LEAK", "SECRET-TOOLINPUT-DO-NOT-LEAK",
                       "/home/redacted", "C:/Users", "repo-x"] {
            XCTAssertFalse(dump.contains(secret), "leaked \(secret)")
        }
    }

    func testRevealOnARemoteWorkspaceCarriesTheEnvironmentOnBothCommands() async {
        let runner = FakeRunner.withEnvironments()
        let id = "repo-x::C:/Users/redacted/work/w1"
        runner.set("terminal list --worktree id:\(id) --json --environment \(RemoteFixtures.winboatId)",
                   #"{"ok":true,"result":{"terminals":[{"handle":"term_remote","connected":true}]}}"#)
        runner.set("terminal switch --terminal term_remote --environment \(RemoteFixtures.winboatId)", "")
        let (c, s) = await merged(runner)
        let key = s.workspaces.first { $0.name == "winboat-1" }!.key
        XCTAssertEqual(key, OrcaDerivation.key(for: id, hostId: RemoteFixtures.winboatId))
        let before = runner.calls.count
        let ok = await c.reveal(workspaceKey: key)
        XCTAssertTrue(ok)
        XCTAssertEqual(Array(runner.calls.dropFirst(before)),
                       [["terminal", "list", "--worktree", "id:\(id)", "--json", "--environment", RemoteFixtures.winboatId],
                        ["terminal", "switch", "--terminal", "term_remote", "--environment", RemoteFixtures.winboatId]])
    }

    func testRevealOnARemoteWorkspaceWithoutLiveTerminalDoesNothingElse() async {
        let runner = FakeRunner.withEnvironments()
        runner.set("terminal list --worktree id:repo-x::/home/redacted/orca/c --json --environment \(RemoteFixtures.cachyId)",
                   #"{"ok":true,"result":{"terminals":[]}}"#)
        let (c, s) = await merged(runner)
        let ok = await c.reveal(workspaceKey: s.workspaces.first { $0.name == "cachy-c" }!.key)
        XCTAssertFalse(ok)
        XCTAssertEqual(runner.callCount("terminal switch"), 0)
    }

    func testEveryEnvironmentCommandIsReadOnly() async {
        let runner = FakeRunner.withEnvironments()
        _ = await merged(runner)
        let verbs = Set(runner.calls.map { $0.prefix(2).joined(separator: " ") })
        XCTAssertEqual(verbs, ["worktree ps", "account list", "orchestration worker-list", "status --json", "environment list"])
    }

    func testHostsEqualityIgnoresLastSuccessSoAnIdleSnapshotIsNotRepublished() async {
        let (c, a) = await merged(.withEnvironments())
        let b = await c.pollEnvironments(full: false, now: now.addingTimeInterval(2), calendar: cal)
        XCTAssertTrue(a.hasSameContent(as: b))
    }
}

final class OrcaSnapshotContentTests: XCTestCase {
    func testActivityMovingWithinTheSameAgoLabelIsNotAChange() async {
        var a = await OrcaCollector(runner: FakeRunner.standard()).collect(now: TestClock.now, calendar: TestClock.utc)
        a.workspaces[0].lastActivityAt = a.generatedAt - 40          // "now"
        var b = a
        b.generatedAt += 3
        b.workspaces[0].lastActivityAt = a.generatedAt - 38 + 3       // still "now", output kept coming
        XCTAssertTrue(a.hasSameContent(as: b))
        b.workspaces[0].lastActivityAt = b.generatedAt - 130          // "2 min": the label changes
        XCTAssertFalse(a.hasSameContent(as: b))
    }
}
