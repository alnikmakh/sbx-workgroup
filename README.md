# workgroup

Run a team of Claude Code agents — a planner / reviewer / executor trio (or
any roles you write) — sharing one git worktree, communicating through a
filesystem-backed "bridge", orchestrated by tmux. One command spins the
whole thing up; one command tears it down.

The runtime is POSIX shell + `tmux` + `git` + `jq` + `yq`. It runs
unchanged on any Linux or macOS host from a plain clone of this repo. An
optional sandboxed mode wraps the same runtime in a Docker sbx microVM
with a shared `cgc` code-graph index; see
[`docs/INSTALL-sbx.md`](docs/INSTALL-sbx.md).

## Why this exists

Running multiple Claude agents on the same worktree is messy: they step on
each other's files, there's no shared history of what they said to each
other, and there's no enforced topology between them. `workgroup` fixes
that:

- **Role separation** — each agent pane gets a different
  `--append-system-prompt` role briefing, so planner / reviewer / executor
  have distinct personalities sharing one worktree. Survives `/clear`
  because it's in the system prompt, not the conversation.
- **Durable audit trail** — inter-agent messages are atomic JSON drops
  into a per-workgroup `bridges/<name>/` directory. You can `cat`, `grep`,
  or replay the whole conversation from another shell.
- **Enforced topology** — edges are declared in the manifest; `bridge-send`
  refuses sends that don't match.
- **One-command lifecycle** — `workgroup up <manifest.yaml>` creates the
  worktree, writes role files, launches one tmux pane per agent.
  `workgroup down` tears it all back down.

## Quickstart (standalone)

```sh
# 1. Prereqs. macOS: brew install tmux git jq yq. Debian/Ubuntu: apt install
#    tmux git jq; yq from Mike Farah's go-yq releases (NOT python yq).
git clone <this-repo> ~/src/workgroup
cd ~/src/workgroup
./workgroup/bin/workgroup doctor     # resolved paths + dependency check

# 2. Write a manifest. Simplest form points at an existing checkout:
cat > ~/projects/my-app/wg-feature.yaml <<'EOF'
name: feature-x
worktree:
  source: ~/projects/my-app        # where the source repo lives
  branch: wg/feature-x
  base: main
agents:
  - { id: planner,  role: planner  }
  - { id: reviewer, role: reviewer }
  - { id: executor, role: executor }
edges:
  - planner -> reviewer
  - reviewer -> planner
  - reviewer -> executor
  - executor -> reviewer
layout: tiled
EOF

# 3. Bring it up and attach.
./workgroup/bin/workgroup up ~/projects/my-app/wg-feature.yaml
./workgroup/bin/workgroup attach feature-x
```

The worktree lands under `~/.local/share/workgroup/worktrees/feature-x/`;
bridge state under `~/.local/share/workgroup/bridges/feature-x/`. No
microVM, no sidecar, nothing under `/etc`. See
[`docs/INSTALL-standalone.md`](docs/INSTALL-standalone.md) for the full
walkthrough, including the `config.yaml` format and `workgroup up`'s
source-resolution order.

To stop: `workgroup down feature-x` archives the bridge; `--force` also
removes the worktree if clean.

## Manifest format

```yaml
name: feature-x              # tmux session name, also bridges/<name>/
worktree:
  source: ~/projects/my-app  # optional; see source-resolution order
  branch: wg/feature-x       # git branch created at worktree-add time
  base: main                 # base branch to fork from
agents:
  - id: planner
    role: planner            # must exist at workgroup/templates/roles/<role>.md
  - id: reviewer
    role: reviewer
  - id: executor
    role: executor
edges:                       # allowed send directions; enforced by bridge-send
  - planner -> reviewer
  - reviewer -> planner
  - reviewer -> executor
  - executor -> reviewer
layout: tiled                # tmux layout: tiled | even-horizontal | even-vertical | main-*
```

`workgroup up <file>` validates the manifest before touching anything.
See `workgroup/examples/bad-*.yaml` for the failure cases the validator
catches (dup agents, unknown role, bad edge, bad name, bad layout).

## Key concepts

- **Workgroup** — a set of agents working together on one task inside one
  git worktree, sharing one bridge namespace and one tmux session.
  Declared in a YAML manifest.
- **Agent** — one `claude` process in a tmux pane, with a role briefing
  in its system prompt.
- **Role** — a named behavior profile, defined by a markdown file injected
  via `claude --append-system-prompt`.
- **Bridge** — the `bridges/<name>/` filesystem namespace used for
  inter-agent messaging. Per-workgroup, atomic writes, plain-file audit
  trail.
- **Signal / doorbell** — a small JSON file atomically dropped into a
  recipient's `inbox/` directory (`write tmp → fsync → rename`).
- **Edge** — a declared `from -> to` pair in the manifest. `bridge-send`
  refuses sends that don't match.

## CLI reference

| Command                                  | What it does                                          |
|------------------------------------------|-------------------------------------------------------|
| `workgroup doctor`                       | Resolved paths + dependency check.                    |
| `workgroup up <manifest.yaml>`           | Validate, create worktree, spawn tmux + agents.       |
| `workgroup down <name> [--force]`        | Kill tmux session, archive bridge, (force: remove worktree). |
| `workgroup ls`                           | List live workgroups.                                 |
| `workgroup attach <name>`                | `tmux attach -t <name>`.                              |
| `workgroup status <name>`                | Pane states + bridge inbox counts.                    |
| `workgroup logs <name> <agent>`          | tail `tmux capture-pane -p` for one agent.            |
| `bridge-send <to> <kind> <file>`         | Send plan/report/note to a peer. Refused if no edge.  |
| `bridge-recv`                            | Drain *my* inbox; moves signals to archive/.          |
| `bridge-peek [--all]`                    | Non-destructive inbox inspection.                     |
| `bridge-watch <name>`                    | inotify-tail the whole bridge namespace.              |

Agent panes have `BRIDGE_DIR`, `AGENT_ID`, `AGENT_PEERS_OUT`,
`AGENT_PEERS_IN` in the environment, so `bridge-send reviewer plan myplan.md`
works from any agent without argument-stuffing.

## Layout

```
workgroup/                  The runtime (one CLI, POSIX sh + jq + yq)
├── bin/
│   ├── workgroup           up / down / ls / attach / status / doctor
│   ├── bridge-send         Atomic signal write into a peer's inbox
│   ├── bridge-recv         Drain signals for current agent
│   ├── bridge-peek         Non-destructive inspect
│   ├── bridge-watch        inotify-driven tail for the watch window
│   └── bridge-init         Per-workgroup bridge bootstrap
├── lib/                    POSIX shell helpers (bridge / manifest / worktree / config)
├── templates/roles/        planner.md, reviewer.md, executor.md
├── examples/               Example + deliberately-broken manifests
├── etc/
│   ├── postinstall.sh      Runs inside the sbx VM; idempotent
│   └── tmux.conf           Optional system tmux config
├── test-bridge.sh          Bridge protocol test suite (32 cases)
├── test-workgroup.sh       End-to-end (39 cases, legacy env-preset path)
└── test-standalone.sh      End-to-end (11 cases, XDG + manifest source)

docs/
├── INSTALL-standalone.md   Linux + macOS standalone install (start here)
├── INSTALL-sbx.md          Optional sbx microVM mode
└── DELIVERY-macos.md       Mac bring-up recipe

sbx/                        Optional: host-side sbx bring-up & teardown
├── provision.sh            Idempotent: sidecar + VM + postinstall
├── teardown.sh             Removes VM and sidecar (preserves cgc data)
└── host-mcp/               cgc sidecar container + mcp_mux multiplexer

plans/                      Phase-by-phase design docs. Read before changing
                            contracts; later phases depend on what's here.
```

## Tests

```sh
./workgroup/test-bridge.sh        # bridge protocol, 32 cases
./workgroup/test-workgroup.sh     # legacy end-to-end, 39 cases
./workgroup/test-standalone.sh    # standalone code path, 11 cases
```

All three run on the host; none need a sandbox. All three must stay green
through every change.

## Sandboxed mode (sbx microVM)

Optional. Wraps the standalone runtime in a Docker `sbx` microVM with a
host-side `cgc` code-graph sidecar reached over MCP. One project = one VM =
one sidecar = one cgc index. Useful when you want kernel-level blast
containment and a persistent, shared code-graph index across every agent.
Full bring-up in [`docs/INSTALL-sbx.md`](docs/INSTALL-sbx.md); the in-VM
flow now produces the same `config.yaml` contract the standalone CLI
consumes, so one codebase serves both modes.

## Design rationale (short version)

- **POSIX shell + `yq`/`jq`**: minimal deps, auditable, easy to iterate.
  Port to Go later if the CLI outgrows shell — the on-disk contracts stay.
- **`--append-system-prompt` over project `CLAUDE.md`**: a shared worktree
  can't use a per-project `CLAUDE.md` to distinguish roles, and system-prompt
  content survives `/clear`.
- **Filesystem bridge over sockets or a broker**: plain-file audit trail,
  atomic via rename, works with `cat`/`grep`/`jq`, survives process death
  and VM rebuilds.
- **Standalone-first**: the runtime should work from a clone on any
  POSIX box. sbx mode is a wrapper that sets up additional isolation, not
  a precondition.

Full history in `plans/00-overview.md` and the per-phase design docs;
phase 08 covers the standalone decoupling.

## Status

Phases 01–06 shipped and in daily use on Linux. Phase 08 (standalone mode
+ macOS portability) shipped on the `standalone-workgroup` branch. Phase
07 (`workgroup resume` for surviving VM auto-stop) is next. macOS delivery
is documented in `docs/DELIVERY-macos.md` but not yet rehearsed end-to-end.

## License

TBD — single-author project, not yet published.
