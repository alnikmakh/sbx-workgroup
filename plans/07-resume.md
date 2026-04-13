# Phase 07 — Resume after VM stop

## Purpose

Make workgroups survive `sbx run` exits. Today, leaving the sandbox means
losing every running tmux session and every in-flight claude pane — the
only durable state is what sits on disk. This phase adds a `workgroup
resume` path that rebuilds a workgroup's tmux session, panes, and watch
window from `/bridge/<name>/state.json` without touching git, so
`workgroup attach` becomes reliable across VM stop/start cycles.

## The problem

`sbx` auto-stops the VM a few seconds after the last interactive shell
exits (see `plans/checkpoints/phase-06.md:64`). Auto-stop kills pid 1,
which takes down the tmux server with every agent pane and
`bridge-watch` it was hosting.

What survives is only what lives on the host mounts:

| Survives                                      | Because                                      |
|-----------------------------------------------|----------------------------------------------|
| `/work/worktrees/<name>` + branch `wg/<name>` | host mount `${projects_root}/<project>`      |
| `/bridge/<name>/state.json` + plans/reports/notes/inbox/outbox/archive | host mount `~/sbx-bridge` |
| role files at `/bridge/<name>/roles/<id>.md`  | same host mount                              |
| cgc index at `${cgc_data_root}/<project>/`    | host-side sidecar, not in the VM at all      |

What does not survive:

- The tmux session `<name>` and every pane inside it.
- Each agent's claude CLI process, its `/clear`-resistant system prompt,
  and any in-pane conversation state the user was relying on.
- The `watch` window's `bridge-watch <name>` tailer.
- Any in-pane shell state (env vars, cwd, scrollback).

Current user-visible symptom: after an `sbx run` exit, `workgroup attach
feature-x` reports "no such session" even though `/work/worktrees/feature-x`
and `/bridge/feature-x/` are both intact on disk. The user has no
supported path back to a working pane layout short of `workgroup down
<name> --force` + `workgroup up examples/<name>.yaml`, which pointlessly
discards the branch state from their last session and forces a
re-briefing.

The state needed to rebuild is all present — `state.json` already
captures agents, edges, worktree path, branch, and role assignments per
the Phase 00 schema. Phase 07's job is to wire a subcommand that
consumes it.

## Scope

### `workgroup resume <name>` (new)

Rebuilds a stopped workgroup's tmux layout from its bridge state, without
re-creating the git worktree, the bridge dir, or the role files.

Responsibilities:

1. Load `/bridge/<name>/state.json` under flock. Error with a precise
   message if missing.
2. Verify the git worktree at `state.json.worktree` still exists on the
   branch recorded in `state.json.branch`. If missing, refuse and point
   the user at `workgroup up` (recovery from a destroyed worktree is
   out of scope — that's a fresh `up`, not a resume).
3. Verify role files exist at `/bridge/<name>/roles/<id>.md` for every
   agent in `state.json.agents`. If any are missing, error — role
   content is load-bearing for `--append-system-prompt` and re-copying
   from templates would silently discard role edits the user made
   mid-session.
4. If a tmux session named `<name>` already exists, print the attach
   command and exit 0 (resume is idempotent — re-running on a live
   session is a no-op).
5. Recreate the session layout exactly as `workgroup up` does: the
   `agents` window with one pane per agent, and the `watch` window
   running `bridge-watch <name>`. Launch each pane via
   `tmux_send_launch` (Phase 04's existing helper), passing the same
   `BRIDGE_DIR`/`AGENT_ID`/`AGENT_PEERS_OUT`/`AGENT_PEERS_IN`/role-file
   arguments computed from `state.json`.
6. Print the `workgroup attach <name>` command.

Non-responsibilities:

- Does **not** restore in-pane conversation history. Each claude pane
  starts a fresh session — same role briefing, empty scrollback. The
  persistence contract is "role + bridge history + worktree", not
  "chat transcript".
- Does **not** replay or re-deliver bridge signals. Anything sitting in
  `inbox/<agent>/` is still there waiting; `bridge-recv` picks up where
  it left off.
- Does **not** touch `state.json` or the git worktree.
- Does **not** re-index cgc (already host-side; nothing to do).

### `workgroup attach <name>` — auto-resume

When `attach` finds no tmux session for `<name>`, instead of failing it
checks for `/bridge/<name>/state.json`. If present, it transparently
runs `workgroup resume <name>` and then attaches. If not, it errors as
today. A `--no-resume` flag preserves the old behavior for users who
want to diagnose a missing session manually.

### `workgroup ls` — include stopped workgroups

Today `workgroup ls` enumerates tmux sessions, so stopped workgroups
disappear entirely. Update to enumerate `/bridge/*/state.json` and cross-
reference with live tmux sessions, marking each row as `running` or
`stopped`. This makes it possible to discover resumable workgroups after
a fresh `sbx run` without remembering their names.

### `workgroup down <name>` — clarify archival semantics

`down` already archives `/bridge/<name>/` to `/bridge/_archive/<name>-<ts>/`,
which means a stopped workgroup that has been `down`ed cannot be resumed —
the state file is gone. That's correct (down is the explicit "I am done"
verb), but the error message from `resume` should say so specifically
rather than generically complaining about a missing `state.json`.

## Inputs

- Phase 03 bridge layout (`state.json` schema) unchanged.
- Phase 04 tmux helpers (`tmux_send_launch`, watch window bringup,
  session-exists checks) — `resume` should reuse them verbatim, not
  fork copies.
- Phase 05 role templates are **not** consulted by resume; the copies
  under `/bridge/<name>/roles/` are authoritative.

No schema changes. No new contracts published.

## Outputs

- `workgroup/bin/workgroup` gains a `resume` verb and updated `attach`
  and `ls` verbs.
- `workgroup/lib/` may gain a small `resume.sh` helper if `bin/workgroup`
  grows too fat — judgement call during implementation.
- `workgroup/test-workgroup.sh` gains coverage: `up` → simulate VM stop
  (kill tmux server) → `resume` → assert session+panes present and
  bridge round-trip still works.

## Verification

1. `workgroup up examples/feature-x.yaml` in a fresh sandbox. Send one
   plan from planner to reviewer. Exit the shell; wait for sbx auto-stop.
2. `sbx run sbx-sbx` again. `workgroup ls` shows `feature-x` as
   `stopped`. `workgroup attach feature-x` auto-resumes and drops into
   the planner pane.
3. In reviewer pane: `bridge-recv` still sees the plan from step 1
   (signal was never consumed).
4. In planner pane: `/clear`, then "what is your role?" — still names
   "planner" (role file survived).
5. `workgroup resume feature-x` on an already-running session is a
   no-op.
6. `workgroup down feature-x`, then `workgroup resume feature-x` — errors
   with "feature-x has been archived; use workgroup up to start fresh".
7. `workgroup resume ghost` where no `/bridge/ghost/` exists — errors
   with "no workgroup named ghost".

Smoke integration: `sbx/scripts/smoke.sh` grows a non-interactive resume
case that runs `workgroup up` → `tmux kill-server` → `workgroup resume`
→ asserts session and panes.

## Open items

- **sbx auto-stop knob.** Before building `resume`, check whether sbx
  exposes a flag to disable or extend auto-stop (e.g. `sbx config`,
  `sbx create --idle-timeout`, or a daemon-side setting). If a clean
  "keep running" option exists and has no serious cost, the resume
  subcommand becomes nice-to-have rather than load-bearing. Resume is
  still worth building — a user on a laptop that slept, a host reboot,
  or a `sbx stop` all produce the same "session gone, state on disk"
  situation — but the urgency drops.
- **Pane scrollback preservation.** Not in scope for v1. If users ask,
  a later phase could `tmux capture-pane -S -` each pane into
  `/bridge/<name>/scrollback/<agent>.log` on a hook or timer, and
  `resume` could prepend that into the new pane. Adds complexity and
  the benefit is cosmetic — deferred.
- **In-claude conversation resume.** Claude Code has no "resume prior
  conversation from a transcript" flag that we can drive from a script.
  If/when it does, `resume` could thread it through. For v1, fresh
  session is the contract.
- **What if state.json is on an older schema.** No schema versioning
  exists today. If a future schema change is needed, bump a `version`
  field in `state.json` and have `resume` refuse unknown versions with
  a precise upgrade message. Not blocking v1.
- **Crash vs. clean-exit distinction.** sbx auto-stop after an interactive
  exit looks identical on disk to a host crash mid-write. `state.json`
  mutations are already flocked, so partial writes aren't a concern —
  but signal delivery (`write tmp → fsync → rename`) could in theory
  leave a stray `tmp` file in an inbox. `resume` should glob and delete
  `*.tmp` under `inbox/*/` as a defensive sweep.
