# How the notch reads Orca

## No watch mode, so it polls

Checked on Orca CLI 1.4.233 (`orca --help`, `orca worktree --help`, `orca status --json`,
`orca agent-context`): there is no `watch`, `stream`, `subscribe`, `follow` or event command, and
`status --json` only reports readiness and capabilities. The runtime socket is internal to Orca and not
a documented contract, so the notch does not talk to it. State is read with the read-only commands
`worktree ps`, `account list`, `orchestration worker-list` and `status`.

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

Remote workspaces, unknown keys and workspaces without a live terminal do nothing. `terminal switch` is
the single non-read command the notch runs (pinned by `OrcaRevealTests`).

## Cost

Measured with `ps -o cputime` deltas over 2 s windows, settled app (60 s after launch), Debug build,
windows where the keyboard and pointer were idle:

| State | Before | After |
|---|---|---|
| Island open, idle | ~18 % | ~1.7 % |
| Island closed (counters), idle | ~18 % | ~1.0 % |
| Island hidden, idle | n/a | ~0.8 % (includes the 15 s polls) |

What changed: the mascot redraws on a rationed schedule (20 fps right after the pointer moved, 10 / 6 fps
open, 4 / 2 fps closed, `MascotPacing`) instead of at the display rate; the pointer is read from the
mouse-moved monitors (throttled to 60 Hz) plus a 10 Hz safety timer only while the island is on screen
(60 Hz only during a drag, no timer when hidden), instead of a 60 Hz timer; the spinners are Core Animation
animations run by the render server; views of the island that were never shown are not mounted; and the
store publishes a snapshot only when its content changed (`OrcaSnapshot.hasSameContent`, which ignores
`generatedAt` and the per-source `lastSuccessAt`).
