# sbx-workgroup

Run a team of Claude Code agents inside an isolated microVM, one per project,
with a shared codebase-graph index and a durable message bus between the
agents. A single command brings up a planner / reviewer / executor trio in
its own git worktree, wired through tmux panes and a filesystem-backed
"bridge" so each agent can message the others without leaving the sandbox.

```
┌────────────── host (Linux or macOS) ──────────────────────────────┐
│                                                                    │
│   cgc-sidecar-<project>   ───►  FalkorDB graph   (127.0.0.1:<port>)│
│        │                                                           │
│        │ HTTP /mcp                                                 │
│        ▼                                                           │
│   sbx microVM "sbx-<project>"                                      │
│     ├── /work        ← ~/My_Projects/<project>   (bind mount)      │
│     ├── /bridge      ← ~/sbx-bridge               (bind mount)     │
│     ├── ~/sbx-worktrees/<project>/  (bind mount, same path)        │
│     └── /opt/workgroup ← this repo's workgroup/   (ro bind mount)  │
│                                                                    │
│     tmux session "feature-x"                                       │
│       ├── window "agents"                                          │
│       │     ├── pane planner   → claude --append-system-prompt …  │
│       │     ├── pane reviewer  → claude --append-system-prompt …  │
│       │     └── pane executor  → claude --append-system-prompt …  │
│       └── window "watch"       → bridge-watch feature-x            │
└────────────────────────────────────────────────────────────────────┘
```

One project = one VM = one sidecar = one cgc index. Arbitrarily many
workgroups (tmux sessions) can run inside that VM at once, all sharing the
same cgc process through the sidecar multiplexer.

## Why this exists

Running multiple Claude agents on the same worktree is messy: they step on
each other's files, there's no shared code index, no durable record of what
they said to each other, and the agent-run-amok blast radius is your whole
laptop. `sbx-workgroup` fixes all four:

- **Isolation** — each project gets a Docker `sbx` microVM (its own kernel),
  so an agent that `rm -rf`s or runs a long process can't reach your host.
- **Shared graph index** — `cgc` (code-graph-context) runs in a host-side
  sidecar container and persists its FalkorDB graph to `~/sbx-cgc-data/`.
  Every agent in the VM queries the same index over MCP.
- **Durable audit trail** — inter-agent messages ("signals") are atomic
  JSON drops into a bind-mounted `~/sbx-bridge/<name>/` directory. You can
  `cat`, `grep`, or replay the whole conversation from the host.
- **Role separation** — each agent pane gets a different
  `--append-system-prompt` role briefing, so planner / reviewer / executor
  (or any roles you write) have distinct personalities sharing one worktree.

## Prerequisites

- **Linux or macOS host.** Development is on Arch Linux; see
  `docs/DELIVERY-macos.md` for the Mac bring-up recipe.
- **[Docker Sandboxes CLI (`sbx`)](https://www.docker.com/products/docker-sandbox/)**,
  v0.24+. Provides the microVM runtime.
- **Docker Engine** — the cgc sidecar is a normal container.
- **Host tools**: `git`, `yq`, `jq`, `curl`, `python3`, `bash ≥ 4`.
  (tmux, flock, inotify-tools, and Claude Code are installed *inside* the
  sandbox by postinstall; the host doesn't need them.)
- **A per-machine config** at `~/.config/sbx-workgroup/machine.yaml`:

  ```yaml
  projects_root: /home/you/My_Projects   # where your project source trees live
  cgc_data_root: /home/you/sbx-cgc-data  # where cgc's graph databases go
  # Optional: pin a specific sidecar port per project
  # port_overrides:
  #   tg-digest: 8850
  ```

  Nothing committed to this repo encodes an absolute host path. Everything
  machine-specific lives in this one file.

## Quickstart

From a fresh checkout of this repo:

```sh
# 1. One-time host config.
mkdir -p ~/.config/sbx-workgroup
cat > ~/.config/sbx-workgroup/machine.yaml <<'EOF'
projects_root: /home/you/My_Projects
cgc_data_root: /home/you/sbx-cgc-data
EOF

# 2. Provision a sandbox for a project. <project> must exist under
#    $projects_root. This starts the cgc sidecar, creates the microVM,
#    installs tmux/git/jq/yq/claude inside, and registers cgc as an MCP
#    server at user scope so every agent pane sees it automatically.
./sbx/provision.sh tg-digest

# 3. Attach. From this point you're inside the sandbox.
sbx run sbx-tg-digest

# 4. Bring up a workgroup. Uses a manifest from workgroup/examples/ (or
#    anywhere on /work). Creates the git worktree, writes role files,
#    launches one tmux pane per agent.
workgroup up /opt/workgroup/examples/tg-digest-main.yaml

# 5. Attach to the tmux session and start working.
workgroup attach tg-digest-main
```

To stop:

```sh
# Inside the sandbox — tears down the tmux session, archives the bridge dir,
# removes the git worktree. Does NOT touch the VM or the cgc index.
workgroup down tg-digest-main

# On the host — removes the VM and the sidecar container. Preserves the
# cgc index under $cgc_data_root/<project>/ so a later provision.sh
# re-attaches to the same graph without reindexing.
./sbx/teardown.sh tg-digest
```

## Layout

```
sbx/                        Host-side bring-up & teardown
├── provision.sh            Idempotent: sidecar + VM + postinstall
├── teardown.sh             Removes VM and sidecar (preserves cgc data)
├── host-mcp/
│   ├── Dockerfile.sidecar  cgc + mcp_mux container image
│   ├── mcp_mux.py          JSON-RPC multiplexer in front of cgc stdio
│   ├── sidecar-up.sh       Start/reuse the project's sidecar container
│   └── sidecar-down.sh     Stop + remove the sidecar container
└── README.md

workgroup/                  In-VM agent runtime (mounted ro at /opt/workgroup)
├── bin/
│   ├── workgroup           Top-level CLI: up / down / ls / attach / status
│   ├── bridge-send         Atomic signal write into a peer's inbox
│   ├── bridge-recv         Drain signals for current agent
│   ├── bridge-peek         Non-destructive inspect
│   ├── bridge-watch        inotify-driven tail for the watch window
│   └── bridge-init         Per-workgroup bridge bootstrap
├── lib/                    POSIX shell helpers (bridge / manifest / tmux / worktree)
├── templates/roles/        planner.md, reviewer.md, executor.md
├── examples/               Example + deliberately-broken manifests
├── etc/
│   ├── postinstall.sh      Runs inside the sandbox; idempotent
│   └── tmux.conf           System tmux config installed at /etc/tmux.conf
├── test-bridge.sh          Bridge protocol test suite
└── test-workgroup.sh       End-to-end workgroup test (runs in a scratch tmux)

plans/                      Phase-by-phase design docs. Read these before changing
                            contracts; later phases depend only on what's here.
├── 00-overview.md          Architecture + shared contracts (start here)
├── 01-vm-provisioning.md   provision.sh / teardown.sh / postinstall.sh
├── 02-mcp-gateway.md       Sidecar + mcp_mux multiplexer design
├── 03-bridge-protocol.md   /bridge/<name>/ layout, signal schema, bridge-*
├── 04-workgroup-cli.md     workgroup up/down/ls/attach + tmux layout
├── 05-roles-and-examples.md Role templates + manifest examples
├── 06-verification.md      Smoke tests and manual verification matrix
└── 07-resume.md            (in progress) workgroup resume after VM auto-stop
```

## Key concepts

- **Workgroup** — a set of agents working together on one task inside one
  git worktree, sharing one bridge namespace and one tmux session. Declared
  in a YAML manifest.
- **Agent** — one `claude` process in a tmux pane, with a role briefing in
  its system prompt.
- **Role** — a named behavior profile (planner, reviewer, executor, …),
  defined by a markdown file injected via `claude --append-system-prompt`.
  Survives `/clear` because it's in the system prompt, not the conversation.
- **Bridge** — the `/bridge/<name>/` filesystem namespace used for
  inter-agent messaging. Host-persisted at `~/sbx-bridge/<name>/`.
- **Signal / doorbell** — a small JSON file atomically dropped into a
  recipient's `inbox/` directory to announce that a payload is ready.
  Atomicity comes from `write tmp → fsync → rename`.
- **Edge** — a declared `from -> to` pair in the manifest. `bridge-send`
  refuses sends that don't match a declared edge — topology is enforced.
- **Sidecar** — the per-project host-side container
  (`cgc-sidecar-<project>`) running `mcp_mux` in front of one long-lived
  `cgc` stdio process.
- **Multiplexer (`mcp_mux`)** — small Python program in the sidecar.
  Accepts many concurrent MCP clients, rewrites JSON-RPC `id` fields to
  avoid cross-session collisions, routes everything to the single cgc
  child. Replaces `docker/mcp-gateway` (wrong lifecycle) and `supergateway`
  (crashes on second concurrent SSE client).

## Manifest format

```yaml
name: feature-x              # tmux session name, also /bridge/<name>/
worktree:
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

## CLI reference

### Host side

| Command                                  | What it does                                          |
|------------------------------------------|-------------------------------------------------------|
| `./sbx/provision.sh <project>`           | Ensure sidecar + VM + postinstall. Idempotent.        |
| `./sbx/teardown.sh <project>`            | Remove VM + sidecar. Preserves cgc data.              |
| `sbx run sbx-<project>`                  | Attach to the sandbox shell.                          |

### In-sandbox

| Command                                  | What it does                                          |
|------------------------------------------|-------------------------------------------------------|
| `workgroup up <manifest.yaml>`           | Validate manifest, create worktree, spawn tmux + agents. |
| `workgroup down <name> [--force]`        | Kill tmux session, archive bridge, remove worktree.   |
| `workgroup ls`                           | List live workgroups in this sandbox.                 |
| `workgroup attach <name>`                | `tmux attach -t <name>`.                              |
| `workgroup status <name>`                | Pane states + bridge inbox counts.                    |
| `workgroup logs <name> <agent>`          | tail `tmux capture-pane -p` for one agent.            |
| `bridge-send <to> <kind> <file>`         | Send plan/report/note to a peer. Refused if no edge.  |
| `bridge-recv`                            | Drain *my* inbox; moves signals to archive/.          |
| `bridge-peek [--all]`                    | Non-destructive inbox inspection.                     |
| `bridge-watch <name>`                    | inotify-tail the whole bridge namespace. (Watch window uses this.) |

Agent panes have `BRIDGE_DIR`, `AGENT_ID`, `AGENT_PEERS_OUT`, `AGENT_PEERS_IN`
already in the environment, so `bridge-send reviewer plan myplan.md` works
from any agent without argument-stuffing.

## Storage map

| What                     | Host location                                   | Lifecycle                                    |
|--------------------------|-------------------------------------------------|----------------------------------------------|
| Project source           | `$projects_root/<project>`                      | Yours; untouched by sbx-workgroup.           |
| Workgroup worktrees      | `~/sbx-worktrees/<project>/<name>/`             | Created on `workgroup up`, removed on `down`. Outside `/work` so cgc doesn't double-index. |
| Bridge                   | `~/sbx-bridge/<name>/`                          | Per-workgroup. `down` moves it to `archive/`. |
| cgc graph DB             | `$cgc_data_root/<project>/`                     | Survives VM rebuilds, survives `teardown.sh`. |
| Sidecar container        | `cgc-sidecar-<project>` (docker)                | `sidecar-up.sh` creates, `sidecar-down.sh` removes. |
| Sandbox VM               | managed by `sbx`                                | `provision.sh` creates, `teardown.sh` removes. |

## Tests

```sh
# Bridge protocol (POSIX, no sandbox needed).
./workgroup/test-bridge.sh

# Full workgroup lifecycle — creates a scratch tmux server in TMUX_TMPDIR,
# exercises `up`/`down`/`ls`/edge enforcement. Safe to run from inside a
# host tmux: the script `unset TMUX TMUX_PANE` to isolate itself.
./workgroup/test-workgroup.sh
```

Both run on the host; they don't need a provisioned sandbox.

## Troubleshooting

- **tmux renders Unicode glyphs as `_`** — locale missing. Reprovision:
  `./sbx/teardown.sh <project> && ./sbx/provision.sh <project>`. Postinstall
  sets `LANG=C.UTF-8` in `/etc/environment`, `/etc/profile.d/locale.sh`,
  and `/etc/bash.bashrc`.
- **`cgc` says "no repositories indexed"** — the sandbox and the sidecar
  are two different filesystems. Tell claude to index **`/work`** (the
  path the sidecar sees), not the host path. Worktrees are deliberately
  not mounted into the sidecar.
- **Sidecar not reachable from the sandbox** — `sbx` applies a Balanced
  network policy. `provision.sh` installs
  `sbx policy allow network localhost:<port>`; if you're on a newer/older
  sbx that renamed the policy, check `sbx policy ls`.
- **`claude /login` fails inside the sandbox** — `provision.sh` adds the
  needed allow rules for `claude.ai`, `auth.anthropic.com`, etc. If you
  added sbx after provisioning, re-run `provision.sh` to refresh policies.
- **In-flight workgroup disappeared after `sbx` auto-stop** — expected for
  now. VM auto-stop kills the tmux server; on-disk state (worktree, bridge,
  cgc index) survives. `workgroup resume` is the Phase 07 work-in-progress
  fix; see `plans/07-resume.md`.

## Design rationale (short version)

- **microVM over plain container**: agent blast radius needs its own kernel.
- **cgc on the host, not in the VM**: the graph DB needs a single writer,
  must survive VM rebuilds, and benefits from native I/O.
- **One sidecar per project, one custom multiplexer per sidecar**:
  `docker/mcp-gateway` spawns its own backends (wrong lifecycle),
  `supergateway` 3.4.3 crashes on the second SSE client. `mcp_mux.py` is
  ~200 lines and does exactly what we need.
- **`--append-system-prompt` over project `CLAUDE.md`**: a shared worktree
  can't use a per-project `CLAUDE.md` to distinguish roles, and system-prompt
  content survives `/clear`.
- **POSIX shell + `yq`/`jq`**: minimal deps, auditable, easy to iterate.
  Port to Go later if the CLI outgrows shell — the on-disk contracts stay.
- **Host-mounted `/bridge`**: survives VM rebuilds, plain-file audit trail,
  works with `cat`/`grep`/`jq` from either side.

Full history in `plans/00-overview.md` and the per-phase design docs.

## Status

All core phases (01–06) shipped and in daily use on Linux. Phase 07
(`workgroup resume` for surviving VM auto-stop) is next. macOS delivery is
documented in `docs/DELIVERY-macos.md` but not yet rehearsed end-to-end.

## License

TBD — single-author project, not yet published.
