import XCTest
@testable import OrcaKit

final class OrcaRevealTests: XCTestCase {
    private let id = "repo-9::/redacted/orcakit"
    private let list = "terminal list --worktree id:repo-9::/redacted/orcakit --json"

    func testPrefersConnectedAgentTerminal() {
        let json = #"{"ok":true,"result":{"terminals":[{"handle":"term_a","connected":true},{"handle":"term_b","connected":false,"agentIdentity":"claude"},{"handle":"term_c","connected":true,"agentIdentity":"claude"}]}}"#
        XCTAssertEqual(OrcaReveal.pickTerminal(from: Data(json.utf8)), "term_c")
        XCTAssertNil(OrcaReveal.pickTerminal(from: Data(#"{"ok":true,"result":{"terminals":[]}}"#.utf8)))
        XCTAssertNil(OrcaReveal.pickTerminal(from: Data("nope".utf8)))
    }

    func testRevealListsThenSwitchesAndNothingElse() async {
        let runner = FakeRunner.standard()
        runner.set(list, #"{"ok":true,"result":{"terminals":[{"handle":"term_x","connected":true}]}}"#)
        runner.set("terminal switch --terminal term_x", "")
        let collector = OrcaCollector(runner: runner)
        let snap = await collector.collect(now: TestClock.now, calendar: TestClock.utc)
        let key = OrcaDerivation.key(for: id)
        XCTAssertTrue(snap.workspaces.contains { $0.key == key })
        let before = runner.calls.count
        let ok = await collector.reveal(workspaceKey: key)
        XCTAssertTrue(ok)
        XCTAssertEqual(Array(runner.calls.dropFirst(before)),
                       [["terminal", "list", "--worktree", "id:\(id)", "--json"],
                        ["terminal", "switch", "--terminal", "term_x"]])
    }

    func testRevealDoesNothingForUnknownOrRemoteWorkspaces() async {
        let runner = FakeRunner.standard()
        let collector = OrcaCollector(runner: runner)
        _ = await collector.collect(now: TestClock.now, calendar: TestClock.utc)
        let before = runner.calls.count
        let unknown = await collector.reveal(workspaceKey: "000000000000")
        XCTAssertFalse(unknown)
        XCTAssertEqual(runner.calls.count, before)
    }
}
