# How the notch reads Orca

## No watch mode, so it polls

Checked on Orca CLI 1.4.233 (`orca --help`, `orca worktree --help`, `orca status --json`,
`orca agent-context`): there is no `watch`, `stream`, `subscribe`, `follow` or event command, and
`status --json` only reports readiness and capabilities. The runtime socket is internal to Orca and not
a documented contract, so the notch does not talk to it. State is read with the read-only commands
`worktree ps`, `account list`, `orchestration worker-list` and `status`, plus the same reads with
`--environment` for the paired remote servers (next section).

## Poll policy (`OrcaPollPolicy`, tested in `OrcaAgentCountsTests`)

| App state | Tick | What a tick reads |
|---|---|---|
| Island on screen (compact or open), Mac awake | 2.5 s | `worktree ps` only (~0.1 s, all the counters and the list need) |
| Island hidden, or Mac / screen asleep | 15 s | a full cycle every tick |
| Any state | every 15 s | a full cycle: also accounts (usage), workers, status |

- Counters therefore lag Orca by at most ~2.5 s while the island is visible. When the island is
  hidden the poll is 15 s; the first tick that finds a running or waiting agent reveals the island, and
  the store immediately switches to the fast rate and refreshes.
- Sleep: `willSleep` / `screensDidSleep` slow the poll to 15 s, `didWake` / `screensDidWake` restore it.
- All CLI work and JSON decoding run in `OrcaCollector` (an actor, processes via `ProcessCommandRunner`);
  the main actor only receives the finished snapshot. A failing source keeps its last good value.
- The island is Mac UI only: hidden costs one 15 s `worktree ps`/full cycle, nothing else (no animation timers,
  no animations).

## Paired remote servers (`--environment`)

Checked on Orca CLI 1.4.233 with two paired servers: `worktree ps`, `orchestration worker-list`, `status`,
`terminal list` and `terminal switch` accept `--environment <id|name>`; `account list` rejects it, so usage
stays local-only. The local `worktree ps` only covers this Mac (its `scope:` line / `hostScope` lists each
paired server under `not covered`, with the flag that reaches it), so a server's workspaces are never in the
local list today. Inside a server's own answer every row has `hostId: "local"` (its own point of view).

- **Discovery**: `environment list --json` at launch and then at most every 60 s (`OrcaCollector.discoveryInterval`).
  Only each server's `id` and `name` are kept, never endpoints, tokens, pairing codes or device ids. A failed
  discovery keeps the known list.
- **Polling**: every enabled server is read in parallel by `OrcaCollector.pollEnvironments`, in its own task
  (`OrcaStore.launchEnvironments`), so a slow server never delays the local cycle or the other servers. Same cadence
  as local: the 2.5 s fast tick reads only `worktree ps`; the 15 s full cycle also reads `orchestration worker-list`
  (`status` is not read for remote servers: `worktree ps` failing is the offline signal). Each server has its own
  10 s timeout (`environmentTimeout`) and its own last-good rows; at most one read per server is in flight, and an
  unreachable server is retried at most once per 15 s.
- **Offline**: a server whose last read failed keeps its last good rows and the open island's footer shows
  `<name> offline`; the other servers and the local list are untouched.
- **Host tag**: every workspace and agent carries `host` (`Local` or the server's name) and `hostId`. Rows of a
  server show its name as a small badge; local rows have none. Keys of a server's rows mix the server id in, so the
  same worktree id on two servers stays two rows.
- **Dedupe**: one row per worktree and host. If a future local `worktree ps` also lists a paired server's rows
  (`host=runtime:<server id>`), the server's own read wins and the local copy is dropped.
- **Counters** sum the agents of all hosts. Settings has "Include remote Orca servers" (default on) and one toggle
  per server; a host that is off is not polled at all (the discovery still lists it so it can be turned back on).
- **Cost**: two extra `orca` processes per fast tick for two paired servers (see Cost).

## Closed-island counters (agents, not workspaces)

Per agent (`OrcaDerivation.agentStatus`), icons as in the Orca sidebar:

- **spinner**: agent state `working`.
- **bell**: agent waiting for input/permission (any state other than `working`/`done`) in a workspace
  active in the last 24 h; or the workspace needs you (unread, a worker that requires action, or a
  failed worker, same 24 h window except failures) and this is the agent that finished last. A workspace
  that needs you but has no done agent rings once for the workspace.
- **check-circle**: agent `done` today (local calendar day) and not carrying a bell. Older `done`
  agents stay idle and uncounted.

Only non-zero counters are drawn. The island keeps itself on screen while there is a spinner or a bell;
finished agents alone do not hold it open, so it folds away as usual once everything is idle.

## Open island

A flat list (no grouping by project) of workspaces that have an agent or a non-idle state, ordered by
the derivation: failed, needs you, running, in review, done; then most recent activity. Rows show state
icon, name, repo, branch, PR, the icons of the agents inside and time since the last activity. The list
scrolls; the footer shows usage per provider (session and week, with reset time).

## Row click: the one non-read command

Orca's CLI has no command that only focuses a workspace (`worktree show` does not open it, and
`worktree create --activate` / `file open` mutate UI state). It has `terminal switch --terminal <handle>`
("Switch to a terminal tab in the UI"), a view change: no agent, repo or workspace state is touched. A
row click therefore runs, off the main actor (`OrcaStore.reveal` -> `OrcaCollector.reveal`, `OrcaReveal`):

1. `terminal list --worktree id:<worktreeId> --json` (read) to find the workspace's live terminals; the
   id stays inside the collector (the public model holds no paths), the row passes its hashed `key`.
2. `terminal switch --terminal <handle>`, preferring a connected terminal that runs an agent.

A row of a paired server does the same with `--environment <server id>` on both commands (terminal handles
belong to the server that issued them; without the flag the CLI answers `terminal_handle_stale`). Verified
against a real server: the call returns `navigated: true`. Rows of SSH targets listed by the local `worktree ps`
(`hostId` other than `local`), unknown keys and workspaces without a live terminal do nothing. `terminal switch`
is the single non-read command the notch runs, locally or with `--environment` (pinned by `OrcaRevealTests` and
`OrcaEnvironmentsTests`).

## Cost

Measured with `ps -o cputime` deltas over 2 s windows, settled app (60 s after launch), Debug build,
windows where the keyboard and pointer were idle:

| State | Before | After |
|---|---|---|
| Island open, idle | ~18 % | ~1.7 % |
| Island closed (counters), idle | ~18 % | ~1.0 % |
| Island hidden, idle | n/a | ~0.8 % (includes the 15 s polls) |

Paired remote servers, same method, same Mac, A/B against `main` (two paired servers, island closed and
idle): 1.15 % before, 1.75 % after (+0.6 points for the two extra `orca` reads per 2.5 s tick). With the island
open the same build pair reads about 21 % both before (20.5 to 22 %) and after (21.5 to 23 %) on the 3440x1440
external display used for this check (a live remote-desktop window sits behind the island), so the remote hosts
add no measurable open-island cost there; the ~1.7 % figure above is from the notch MacBook.

A terminal that prints all the time (a remote desktop session on a paired server) moves `lastActivityAt` on every
poll. `OrcaSnapshot.hasSameContent` compares activity times by the label they draw (`now`, `N min`, `N h`, `N d`),
so that does not re-render the island on every tick; without it the open island redrew every 2.5 s.

What changed: the mascot redraws on a rationed schedule (20 fps right after the pointer moved, 10 / 6 fps
open, 4 / 2 fps closed, `MascotPacing`) instead of at the display rate; the pointer is read from the
mouse-moved monitors (throttled to 60 Hz) plus a 10 Hz safety timer only while the island is on screen
(60 Hz only during a drag, no timer when hidden), instead of a 60 Hz timer; the spinners are Core Animation
animations run by the render server; views of the island that were never shown are not mounted; and the
store publishes a snapshot only when its content changed (`OrcaSnapshot.hasSameContent`, which ignores
`generatedAt` and the per-source `lastSuccessAt`).
