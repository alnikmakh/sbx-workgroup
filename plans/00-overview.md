# Phase 00 — Overview & shared contracts

## Purpose

Single source of truth for things every other phase references: the architecture, the on-disk contracts between phases, the glossary, and the "why these choices" rationale. No code is produced in this phase.

## Architecture

```
Host (Linux or macOS)
│
├── Per-project MCP sidecars (Phase 02, one container per project)
│   ├── cgc-sidecar-<project-a>  :127.0.0.1:<hash(a)>  → DB: ${cgc_data_root}/project-a/
│   ├── cgc-sidecar-<project-b>  :127.0.0.1:<hash(b)>  → DB: ${cgc_data_root}/project-b/
│   └── cgc-sidecar-<project-c>  :127.0.0.1:<hash(c)>  → DB: ${cgc_data_root}/project-c/
│       (each container = mcp_mux multiplexer + one cgc stdio child)
│
├── ${projects_root}/<project>/    ─┐
├── ~/sbx-bridge/                    ┼─ bind-mounted into VM
│                                    │
└── sbx microVM (one per project) ◄┘  + sbx create --publish <hash(project)>:8811
    │
    ├── mounts
    │   ├── /work           ← project repo + /work/worktrees/<name>
    │   ├── /bridge         ← agent messaging, host-persisted
    │   └── /opt/workgroup  ← CLI payload (bin/, lib/, templates/, etc/)
    │
    ├── packages: claude-code, tmux, git, inotify-tools, yq, jq, flock
    │             (no docker in the VM — MCP stack lives on host)
    │
    ├── one-time: claude mcp add --transport http cgc http://127.0.0.1:8811/mcp
    │
    └── tmux
        ├── session "feature-a"   ← workgroup A
        │   ├── window "agents"
        │   │   ├── pane planner   → claude --append-system-prompt <role>
        │   │   ├── pane reviewer  → claude --append-system-prompt <role>
        │   │   └── pane executor  → claude --append-system-prompt <role>
        │   └── window "watch"     → bridge-watch feature-a
        └── session "feature-b"   ← workgroup B, fully isolated
```

## Shared contracts

Every later phase depends on these contracts — and only on these. Changing any of them requires updating this file first.

### Mount points (defined by Phase 01)

| Path inside VM | Host source                         | Purpose                                  |
|----------------|-------------------------------------|------------------------------------------|
| `/work`        | `${projects_root}/<project>`        | Project repo; `/work/worktrees/<name>` per workgroup |
| `/bridge`      | `~/sbx-bridge`                      | Agent messaging (host-persisted)         |
| `/opt/workgroup` | copied from this repo during postinstall | CLI payload (`bin/`, `lib/`, `templates/`, `etc/`) |

`${projects_root}` and `${cgc_data_root}` come from the per-machine config file `~/.config/sbx-workgroup/machine.yaml` (Phase 02 contract). Nothing committed to this repo encodes an absolute host path.

### Host port + sandbox reachability (Phase 02 owns the hash, Phase 01 opens the path)

Each project's sidecar listens on a hashed host port: `8000 + (crc32(project) mod 1000)`. `machine.yaml` may override any project's port via a `port_overrides:` block.

`sbx` sandboxes reach the host via the gateway name `host.docker.internal`, with all outbound HTTP routed through a policy-enforcing proxy at `gateway.docker.internal:3128` (set in `HTTP_PROXY`/`HTTPS_PROXY`; `NO_PROXY=localhost,127.0.0.1,::1`). Phase 01's `provision.sh` opens the path with `sbx policy allow network localhost:<host-port>` — the proxy canonicalizes `host.docker.internal:<port>` to `localhost:<port>`, so that one allow rule is what lets the sandbox reach the sidecar. `sbx ports --publish` is **not** used: it is inbound (host → sandbox) and points the wrong direction.

In-sandbox MCP endpoint: `http://host.docker.internal:<host-port>/mcp`. The hashed port is passed into the sandbox as the `SIDECAR_PORT` env var at postinstall time and recorded in `/etc/workgroup/sidecar-port` so Phase 04 can read it when constructing `claude mcp add`.

### Sidecar lifecycle contract (Phase 02 provides, Phase 01 drives)

- `sbx/host-mcp/sidecar-up.sh <project>` — idempotent; starts (or recognizes) the project's sidecar container, waits for `/mcp` to answer, prints the chosen host port on its own line to stdout, exit 0.
- `sbx/host-mcp/sidecar-down.sh <project>` — stops and removes the project's sidecar container. No refcount. Does not touch `${cgc_data_root}/<project>/`.
- Container naming: `cgc-sidecar-<project>`; label: `sbx.project=<project>`.
- Sidecar lifecycle is coupled 1:1 to the project's VM. Phase 01's `provision.sh` calls `sidecar-up.sh` before `sbx create`; Phase 01's teardown path calls `sidecar-down.sh` after `sbx delete`.

### `/bridge/<name>/` directory layout (Phase 03)

```
/bridge/<name>/
├── state.json                 # workgroup metadata (see schema below)
├── state.json.lock            # flock target for state mutations
├── .counters/<agent-id>       # per-agent monotonic signal counter
├── roles/<agent-id>.md        # role briefings, copied from templates at `up` time
├── plans/<id>.md              # message payloads
├── reports/<id>.md
├── notes/<id>.md
├── inbox/<agent-id>/<id>.json # doorbell signals delivered to agent
├── outbox/<agent-id>/<id>.json # local copy of what agent sent (audit)
└── archive/<id>.json          # processed signals moved here
```

### `state.json` schema (Phase 03 writes helpers; Phase 04 populates it)

```json
{
  "name": "feature-x",
  "created_at": "2026-04-12T10:15:03Z",
  "worktree": "/work/worktrees/feature-x",
  "branch": "wg/feature-x",
  "agents": [
    {"id": "planner",  "role": "planner"},
    {"id": "reviewer", "role": "reviewer"},
    {"id": "executor", "role": "executor"}
  ],
  "edges": [
    {"from": "planner",  "to": "reviewer"},
    {"from": "reviewer", "to": "planner"},
    {"from": "reviewer", "to": "executor"},
    {"from": "executor", "to": "reviewer"}
  ]
}
```

Mutations to `state.json` must be serialized with `flock`.

### Signal JSON schema (Phase 03)

```json
{
  "id": "2026-04-12T10-15-03Z-planner-001",
  "from": "planner",
  "to": "reviewer",
  "kind": "plan",
  "payload": "plans/2026-04-12T10-15-03Z-planner-001.md",
  "subject": "Initial plan for OAuth refactor",
  "created_at": "2026-04-12T10:15:03Z"
}
```

Signals are written via atomic `write tmp → fsync → rename` into the recipient's `inbox/<to>/`. `payload` is a path relative to `/bridge/<name>/`.

Allowed values of `kind`: `plan`, `report`, `note`. These map one-to-one to the payload subdirectories `plans/`, `reports/`, `notes/`. `bridge-send` rejects any other kind.

### MCP endpoint (Phase 02)

`http://host.docker.internal:<host-port>/mcp` — served by the **project's host-side sidecar**, reached from inside the sandbox through the policy-gated HTTP proxy (allow rule added by `provision.sh`). The hashed host port is available inside the sandbox as `$SIDECAR_PORT` and at `/etc/workgroup/sidecar-port`. Registered in each Claude session once with:

```
claude mcp add --transport http cgc "http://host.docker.internal:$(cat /etc/workgroup/sidecar-port)/mcp"
```

One project = one VM = one sidecar = one cgc process = one DB. Inside the VM, arbitrarily many Claude sessions (across arbitrarily many workgroups) all share that single cgc process through the sidecar's multiplexer. Cross-project visibility doesn't exist and isn't needed — each VM only ever talks to its own project's cgc index.

### Environment variables in each agent pane (Phase 04)

| Var               | Example                                | Meaning                                    |
|-------------------|----------------------------------------|--------------------------------------------|
| `BRIDGE_DIR`      | `/bridge/feature-x`                    | Workgroup bridge namespace                 |
| `AGENT_ID`        | `planner`                              | This agent's id                            |
| `AGENT_PEERS_OUT` | `reviewer`                             | Comma-separated ids this agent may send to |
| `AGENT_PEERS_IN`  | `reviewer`                             | Comma-separated ids this agent may receive from |

## Glossary

- **Workgroup** — a set of agents working together on one task inside one git worktree, sharing one bridge namespace and one tmux session.
- **Agent** — one `claude` process running in a tmux pane, with a role briefing in its system prompt.
- **Role** — a named behavior profile (planner, reviewer, executor, …). Defined by a markdown file injected via `claude --append-system-prompt`.
- **Bridge** — the `/bridge/<name>/` filesystem namespace used for inter-agent messaging.
- **Signal** — a small JSON file dropped atomically into a recipient's inbox to announce that a payload is ready.
- **Doorbell** — synonym for signal; emphasizes the "notify" role as distinct from the payload itself.
- **Edge** — a declared `from -> to` pair in the manifest; `bridge-send` refuses sends that don't match a declared edge.
- **Worktree** — a `git worktree` at `/work/worktrees/<name>`, one per workgroup.
- **Pane** — a tmux pane; one pane per agent.
- **Sidecar** — the per-project host-side container (`cgc-sidecar-<project>`) that runs the `mcp_mux` multiplexer in front of one long-lived `cgc` stdio process, exposing MCP over streamable HTTP on a hashed host port.
- **Multiplexer (`mcp_mux`)** — the small Python program inside each sidecar. Accepts many concurrent MCP clients, rewrites JSON-RPC `id` fields to avoid collisions across sessions, and routes every request/response in or out of the one cgc stdio child.

## Design rationale

- **microVM over plain container (Docker sbx)**: each sandbox gets its own kernel. Agents that install packages, spin up long-lived processes, or run tooling are less risky in a VM than in a shared-kernel container. *Agents* stay entirely inside the VM.
- **cgc on the host, not in the VM**: cgc's graph index has to survive VM rebuilds, must have exactly one writer per DB directory, and benefits from native I/O. Running cgc on the host gives all three for free. The sidecar container is the one host-touching piece the user runs per project — agents never touch it.
- **One sidecar per project, one custom multiplexer inside each sidecar**: two earlier candidates were rejected. `docker/mcp-gateway` spawns its own backends from OCI images on demand, violating the single-writer invariant. `supergateway` 3.4.3 crashes on the second concurrent SSE client. So each sidecar runs a small purpose-built JSON-RPC multiplexer (`mcp_mux.py`) that fans arbitrarily many MCP clients into one long-lived cgc stdio child. Full history in `plans/02-mcp-gateway.md`.
- **Docker `sbx` `--publish` for host↔VM wiring**: `--publish <host-port>:8811` at VM-create time gives every VM transparent access to its project's sidecar at `127.0.0.1:8811` inside the guest. No MCP config inside the VM beyond one `claude mcp add` line per VM.
- **FalkorDB Lite (with Kùzu fallback), not Neo4j**: embedded in-process graph backend means each cgc container is cheap, the DB is a plain directory on the host, and there's no JVM or second server per project.
- **`--append-system-prompt` over project `CLAUDE.md`**: all agents in a workgroup share one worktree, so a project-level `CLAUDE.md` can't distinguish roles. `--append-system-prompt` injects content into the system prompt, which is *not* wiped by `/clear` — load-bearing for durable role identity.
- **POSIX shell + `yq`/`jq` for v1**: minimal dependencies, auditable, easy to iterate. If the CLI outgrows shell, we port `workgroup` to Go later without changing the on-disk contracts defined here.
- **Host-mounted `/bridge`**: survives VM rebuilds, gives a durable audit trail, and lets you inspect plans/reports with normal tools.
- **Claude's native `/sandbox` is not used**: the microVM is already the isolation boundary; adding bubblewrap on top would interfere with tmux.

## Out of scope for v1

- Cross-workgroup messaging.
- Auth on the MCP gateway (bound to `127.0.0.1` only).
- Distributed sbx across multiple hosts.
- A persistent agent-activity dashboard (we rely on `bridge-watch` + `tmux capture-pane`).
- Automatic merging of workgroup worktrees back into main.
