## Sandboxed mode (sbx microVM)

Run a workgroup inside an isolated microVM, one per project, with a shared
codebase-graph index (cgc) reached over MCP. This is the original delivery
mode of the tool; as of phase 08 the standalone mode
(`docs/INSTALL-standalone.md`) is the default and sbx is one optional
deployment on top of the same runtime.

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
│       │     ├── pane planner   → claude --append-system-prompt …   │
│       │     ├── pane reviewer  → claude --append-system-prompt …   │
│       │     └── pane executor  → claude --append-system-prompt …   │
│       └── window "watch"       → bridge-watch feature-x            │
└────────────────────────────────────────────────────────────────────┘
```

One project = one VM = one sidecar = one cgc index. Arbitrarily many
workgroups (tmux sessions) can run inside that VM at once, all sharing the
same cgc process through the sidecar multiplexer.

## Why sbx mode

- **Isolation** — each project gets a Docker `sbx` microVM (its own kernel),
  so an agent that `rm -rf`s or runs a long process can't reach your host.
- **Shared graph index** — `cgc` (code-graph-context) runs in a host-side
  sidecar container and persists its FalkorDB graph to `~/sbx-cgc-data/`.
  Every agent in the VM queries the same index over MCP.
- **Durable audit trail** — inter-agent messages ("signals") are atomic
  JSON drops into a bind-mounted `~/sbx-bridge/<name>/` directory. You can
  `cat`, `grep`, or replay the whole conversation from the host.

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

```sh
# 1. One-time host config.
mkdir -p ~/.config/sbx-workgroup
cat > ~/.config/sbx-workgroup/machine.yaml <<'EOF'
projects_root: /home/you/My_Projects
cgc_data_root: /home/you/sbx-cgc-data
EOF

# 2. Provision a sandbox for a project. <project> must exist under
#    $projects_root. This starts the cgc sidecar, creates the microVM,
#    installs tmux/git/jq/yq/claude inside, and writes
#    /var/lib/workgroup/config.yaml so the standalone dispatcher finds the
#    cgc MCP entry automatically at `workgroup up` time.
./sbx/provision.sh tg-digest

# 3. Attach. From this point you're inside the sandbox.
sbx run sbx-tg-digest

# 4. Bring up a workgroup.
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

## Runtime contract inside the sandbox

Phase 08 part 2: the in-VM flow writes a single `config.yaml` consumed by
the same dispatcher the standalone mode uses. `postinstall.sh` writes:

- `/var/lib/workgroup/config.yaml` — `bridge_root`, `worktree_root`, and an
  `mcp:` block with the cgc endpoint at
  `http://host.docker.internal:$SIDECAR_PORT/mcp`.
- `/etc/profile.d/workgroup.sh` — exports `WORKGROUP_HOME` and
  `WORKGROUP_CONFIG` so every login shell sees them. Also mirrored into
  `/etc/bash.bashrc` for non-login interactive shells.

The legacy `/etc/workgroup/{sidecar-port,worktree-root}` files are gone.
`/work`, `/bridge`, and `/opt/workgroup` remain as convenience symlinks
into `$WORK_SRC`, `$BRIDGE_SRC`, and `$WORKGROUP_SRC`.

## Sidecar + MCP

The per-project host-side sidecar (`cgc-sidecar-<project>`) runs
`mcp_mux.py` in front of one long-lived `cgc` stdio process. Every
`workgroup up` registers `cgc` at user scope for the sandbox user via the
dispatcher's MCP loop, which reads the `mcp:` block from
`/var/lib/workgroup/config.yaml`. Failures are warnings, not fatal — a
workgroup with no cgc still runs; the agents just can't query the graph.

## sbx-specific troubleshooting

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

## Storage map

| What                     | Host location                                   | Lifecycle                                    |
|--------------------------|-------------------------------------------------|----------------------------------------------|
| Project source           | `$projects_root/<project>`                      | Yours; untouched by sbx-workgroup.           |
| Workgroup worktrees      | `~/sbx-worktrees/<project>/<name>/`             | Created on `workgroup up`, removed on `down`. Outside `/work` so cgc doesn't double-index. |
| Bridge                   | `~/sbx-bridge/<name>/`                          | Per-workgroup. `down` moves it to `archive/`. |
| cgc graph DB             | `$cgc_data_root/<project>/`                     | Survives VM rebuilds, survives `teardown.sh`. |
| Sidecar container        | `cgc-sidecar-<project>` (docker)                | `sidecar-up.sh` creates, `sidecar-down.sh` removes. |
| Sandbox VM               | managed by `sbx`                                | `provision.sh` creates, `teardown.sh` removes. |

## Design rationale (sbx-specific bits)

- **microVM over plain container**: agent blast radius needs its own kernel.
- **cgc on the host, not in the VM**: the graph DB needs a single writer,
  must survive VM rebuilds, and benefits from native I/O.
- **One sidecar per project, one custom multiplexer per sidecar**:
  `docker/mcp-gateway` spawns its own backends (wrong lifecycle),
  `supergateway` 3.4.3 crashes on the second SSE client. `mcp_mux.py` is
  ~200 lines and does exactly what we need.
- **Host-mounted `/bridge`**: survives VM rebuilds, plain-file audit trail,
  works with `cat`/`grep`/`jq` from either side.
