# Phase 02 — Per-project MCP sidecar (multiplexer + cgc)

## Purpose

Stand up a **per-project sidecar container** on the host that wraps a single, long-lived `codegraphcontext` (cgc) stdio process and exposes it to the matching sbx microVM over streamable HTTP. One project = one VM = one sidecar = one cgc process = one FalkorDB Lite directory. N Claude Code sessions running inside the VM (across arbitrarily many workgroups) all share that single cgc process through a small JSON-RPC multiplexer that lives inside the sidecar container.

The sidecar has exactly one job: **safely fan many MCP clients into one stdio MCP server without letting them trip over each other's JSON-RPC `id`s and without ever starting a second cgc process against the same DB.**

## Why a custom multiplexer (history)

Two earlier candidates were tested and rejected:

1. **`docker/mcp-gateway:latest`.** Its catalog model spawns MCP backends itself from OCI images on demand, with no way to route to a pre-existing sibling container. That directly violates the single-writer-per-DB invariant. Verified against `docker/mcp-gateway:latest` 2026-04-12; see the earlier drafts of this file and `.tmp/gateway-hotreload-test/` for reproducers.
2. **`supergateway` (supercorp-ai/supergateway) 3.4.3.** SSE transport crashes on the second concurrent client with `Error: Already connected to a transport` — the shared `Server` instance can only be wired to one transport at a time. Verified 2026-04-12; full reproducer under `.tmp/supergateway-concurrency-test/`. The `streamableHttp` transport has some `--stateful` plumbing but was not validated, and we decided not to bet the architecture on a tool whose primary design point is 1:1 bridging.

Writing our own ~200–300 line multiplexer is cheaper than continuing to evaluate off-the-shelf tools against our very specific invariant, and it gives us a codebase we fully understand when something misbehaves.

## Which cgc backend

Unchanged from the previous draft: **FalkorDB Lite** on Linux/macOS (in-process, embedded, fast), with **KùzuDB** as a portable fallback. Neo4j is not used. Each project's DB is a plain directory on the host filesystem at `${cgc_data_root}/<project>/`.

## Architecture

```
┌─ host ─────────────────────────────────────────────────┐
│                                                        │
│  sidecar container: cgc-sidecar-<project>              │
│    listens 127.0.0.1:<hashed-port>  (PID 1: mcp_mux)   │
│        │                                               │
│        │  line-delimited JSON over stdin/stdout        │
│        ▼                                               │
│    child process: cgc mcp start  (singleton, PID 2)    │
│        │                                               │
│        ├─ /work        ← ro bind ${projects_root}/<p>  │
│        └─ /root/.cgc   ← rw bind ${cgc_data_root}/<p>  │
│                                                        │
└────────────────────────────────────────────────────────┘
                            ▲
                            │ sbx create --publish <hashed-port>:8811
                            ▼
                ┌───────────────────────────┐
                │  sbx VM for <project>     │
                │                           │
                │  claude mcp add --transport http \
                │      cgc http://127.0.0.1:8811/mcp
                │                           │
                │  tmux: N workgroups,      │
                │        M claude panes     │
                │        total              │
                └───────────────────────────┘
```

One container, two processes, single DB. The multiplexer is PID 1 of the container and owns the lifetime of cgc — if cgc dies, the multiplexer restarts it and fails any in-flight requests with a clean error; if the multiplexer dies, the container exits and `sidecar-up.sh` (or the user) brings it back.

## Scope

### Host-local config: `~/.config/sbx-workgroup/machine.yaml` (unchanged)

```yaml
projects_root: /home/aleksandr/My_Projects
cgc_data_root: /home/aleksandr/sbx-cgc-data
```

Never committed. Same contract as before.

### `sbx/host-mcp/Dockerfile.sidecar`

One image, used for every project's sidecar. Contents:

- Python 3.12 slim base.
- `pip install "codegraphcontext[falkordb]"` (with Kùzu fallback).
- `pip install fastapi uvicorn` (or `starlette` — whichever the multiplexer picks).
- Copies `mcp_mux.py` to `/opt/mcp_mux.py`.
- `ENTRYPOINT ["python3", "/opt/mcp_mux.py"]`.
- `EXPOSE 8811`.

Built once; every sidecar container uses the same image tag (`sbx-cgc-sidecar:local`). No per-project customization at build time — the project name, mount paths, and anything else project-specific arrive via environment variables at `docker run` time.

### `sbx/host-mcp/mcp_mux.py` — the multiplexer

Single-file Python program. Behavior (not line-by-line implementation — that's for the implementation step):

**Startup.**
1. Reads env: `MUX_PROJECT` (label only), `MUX_BACKEND_CMD` (default: `cgc mcp start`), `MUX_PORT` (default: `8811`).
2. Spawns the backend command as a child process with pipes on stdin/stdout/stderr. stderr is streamed to the sidecar's own stderr.
3. Starts a background reader task that consumes the child's stdout line-by-line, parses each line as JSON, and routes it (see "Response routing" below).
4. Starts an HTTP server on `0.0.0.0:${MUX_PORT}` serving the MCP streamable HTTP transport at `/mcp`.

**Session handling.**
- Each incoming MCP client is identified by the `Mcp-Session-Id` header (generated on the server side at `initialize`, returned to the client, sent back on every subsequent request). The multiplexer keeps a `sessions` dict: `session_id → SessionState`.
- `SessionState` holds: the client's declared protocol version, a mapping `client_req_id → mux_req_id`, and an SSE response queue for streamed notifications destined for this client.

**Request routing (client → backend).**
1. Client POSTs a JSON-RPC request with some `id` (call it `client_id`).
2. Multiplexer allocates a monotonic global `mux_id` from a single counter. Stores `sessions[session_id].pending[client_id] = mux_id` and the reverse `global_pending[mux_id] = (session_id, client_id)`.
3. Rewrites the request's `id` field to `mux_id`. If the request carries an MCP progress token or similar client-scoped reference, rewrite those too (TBD once we enumerate them — see open items).
4. Serializes to one line of JSON, writes to the backend's stdin, flushes.
5. The HTTP handler awaits the future stored under `global_pending[mux_id]` and returns the eventual response.

**Response routing (backend → client).**
1. Background reader parses a line from stdout as JSON-RPC.
2. If it has an `id` and that id is in `global_pending`: look up `(session_id, client_id)`, rewrite `id` back to `client_id`, resolve the awaiting future with the response, drop the pending entry.
3. If it has no `id` (notification): broadcast to every session's SSE queue, or — once we know which notifications are session-scoped — route to the originating session only. Starting assumption: broadcast, revisit after we see real cgc traffic.
4. If the `id` is unknown: log and drop. Shouldn't happen.

**Backend failure.**
- If the backend exits unexpectedly, the multiplexer:
  1. Fails all futures in `global_pending` with a JSON-RPC error (`-32000`, message `"backend crashed"`).
  2. Clears all session state (forces clients to re-initialize).
  3. Respawns the backend (bounded: max 5 restarts in 60 s, otherwise the multiplexer itself exits and docker's `restart: unless-stopped` takes over).

**Concurrency correctness.**
- The backend's stdin is written to from a single task (the one servicing the inbound HTTP request). Multiple concurrent writes are serialized behind an `asyncio.Lock` to keep JSON lines atomic.
- The backend's stdout is read from a single task. That's the only reader, so the JSON parser never races.
- Sessions don't share mutable state; each has its own pending map.

**What the multiplexer explicitly does NOT do.**
- It does not understand MCP semantically. It rewrites ids, routes responses, and forwards notifications. It does not inspect method names or tool arguments.
- It does not do auth (the listening socket is behind the container's port binding, which is behind `127.0.0.1` on the host).
- It does not persist session state — a sidecar restart wipes all sessions and clients must reinitialize. Fine: sessions are short-lived.

### Port hashing

Port is derived deterministically from the project name so the same project always gets the same port and two invocations of `sidecar-up.sh` for the same project can recognize "already running."

```
port = 8000 + (crc32(project_name) mod 1000)   # range: 8000-8999
```

Collision handling:
- If the computed port is already bound on the host **by something other than this project's sidecar container**, `sidecar-up.sh` errors out with a message naming the conflicting port and pointing the user at an override path.
- Override path: `machine.yaml` may optionally contain a `port_overrides:` block mapping project name → explicit port. `sidecar-up.sh` honors that before falling back to the hash.
- Two different projects hashing to the same port is treated as a collision the same way.

### `sbx/host-mcp/sidecar-up.sh`

Usage: `./sidecar-up.sh <project>`. Exit 0 on success; prints the chosen host port to stdout on its own line (nothing else on stdout) so callers can capture it with `port=$(./sidecar-up.sh astro-blog)`.

Steps:
1. Load `machine.yaml`; resolve `projects_root`, `cgc_data_root`, and any `port_overrides`.
2. Resolve the project's on-disk directory (respecting an optional `alias` field if we keep one; starting assumption: no alias, `<project>` == directory basename).
3. Compute the host port (override or hash).
4. Check for an existing container with label `sbx.project=<project>`:
   - Running: print its port, exit 0 (idempotent).
   - Exited: `docker rm` it, fall through to create.
5. Verify the port is free (skip if the answer from step 4 was "already running").
6. Ensure `${cgc_data_root}/<project>/` exists (`mkdir -p`).
7. `docker run -d --restart=unless-stopped` with:
   - `--name cgc-sidecar-<project>`
   - `--label sbx.project=<project>`
   - `-p 127.0.0.1:<host-port>:8811`
   - `-v ${projects_root}/<project>:/work:ro`
   - `-v ${cgc_data_root}/<project>:/root/.cgc`
   - `-e MUX_PROJECT=<project>`
   - `sbx-cgc-sidecar:local`
8. Wait briefly (bounded: e.g. 10 s) for `/mcp` to answer a health probe. Fail with the container's last 50 log lines if not.
9. Print the host port.

Idempotent. Re-running `sidecar-up.sh astro-blog` when the sidecar is already up is a no-op that still prints the port.

### `sbx/host-mcp/sidecar-down.sh`

Usage: `./sidecar-down.sh <project>`. Stops and removes the container for that project. Exit 0 if already gone. Does not touch `${cgc_data_root}/<project>/`.

No refcounting. Sidecar lifecycle is **coupled 1:1 with the project's VM**, and the VM's lifecycle is owned by Phase 01's `provision.sh` / teardown path. Phase 01 decides when the sidecar comes up and goes down; Phase 02 only provides the primitives.

### `sbx/host-mcp/build.sh`

Builds `sbx-cgc-sidecar:local` from `Dockerfile.sidecar`. Idempotent (docker's own layer cache). Called once manually, or automatically from `sidecar-up.sh` on first invocation if the image is missing.

### One-time Claude registration inside the VM

```
claude mcp add --transport http cgc http://127.0.0.1:8811/mcp
```

The guest port is always `8811` regardless of the hashed host port — the host-to-guest publish translates. One line per VM, written once at postinstall time. Already covered by Phase 01.

## Inputs

- Host has docker.
- Host has `~/.config/sbx-workgroup/machine.yaml` populated.
- Host has the project's source tree present at `${projects_root}/<project>`.

## Outputs / contracts published

- `sbx-cgc-sidecar:local` image on the host, built from `Dockerfile.sidecar`.
- `sidecar-up.sh <project>` → exit 0, stdout = chosen host port on its own line.
- `sidecar-down.sh <project>` → exit 0, container gone.
- Container label scheme: `sbx.project=<project>` (Phase 01's teardown can query this).
- Port hashing algorithm: `8000 + (crc32(project) mod 1000)`, documented so Phase 01 can reproduce it independently if it ever needs to.
- Inside-VM endpoint: `http://127.0.0.1:8811/mcp` (fixed, not hashed — the hash is host-side only).
- Single Claude registration command (above), documented.

Phase 01 depends on these and nothing else from this phase.

## Verification

1. `./sbx/host-mcp/build.sh` builds the image without error.
2. `./sbx/host-mcp/sidecar-up.sh astro-blog` exits 0, prints a port in 8000-8999, `docker ps` shows `cgc-sidecar-astro-blog` running.
3. `curl -sS http://127.0.0.1:<port>/mcp` returns an MCP handshake response (non-error).
4. Re-running `sidecar-up.sh astro-blog` is a no-op and prints the same port.
5. **Concurrency check (the load-bearing test).** Point two concurrent MCP clients at the sidecar, have each call a cgc tool at overlapping times. Expected: both calls succeed, `docker exec cgc-sidecar-astro-blog ps` shows **exactly one** cgc child process, and the multiplexer's log shows client-id rewriting happened.
6. Kill the cgc child (`docker exec cgc-sidecar-astro-blog pkill -f 'cgc mcp start'`) and fire a new client call. Expected: multiplexer respawns cgc, in-flight requests receive a clean error, subsequent requests succeed.
7. `./sbx/host-mcp/sidecar-down.sh astro-blog` exits 0, container gone, `${cgc_data_root}/astro-blog/` still intact on disk.
8. After a `sidecar-down.sh` / `sidecar-up.sh` cycle, a cgc query that previously returned data returns the same data without reindexing (proves the DB survived).
9. From inside a provisioned sbx VM: `curl -sS http://127.0.0.1:8811/mcp` succeeds, `claude mcp list` shows `cgc` connected, a tool call against `/work` returns a real response.

## Open items

- **Notification routing.** Starting assumption: broadcast. If cgc uses notifications for anything session-scoped (progress tokens, cancellation, log events), we'll need per-session routing. Revisit once we see real traffic under load. Contained to `mcp_mux.py` — not a contract change.
- **Progress token rewriting.** MCP progress tokens are client-issued identifiers that must survive the round-trip like request ids. Enumerate which fields carry them (`_meta.progressToken` is the main one) and rewrite them symmetrically. Defer the full implementation until the first request/response path is working.
- **Maximum in-flight requests per session.** Unbounded in v1. Add a cap if we see memory growth from stuck sessions.
- **Port hashing collisions.** Mitigated by `port_overrides` in `machine.yaml`. Not an algorithmic worry at our scale (handful of projects) but documented as a known knob.
- **cgc live-watch vs. explicit reindex.** Unchanged from the previous draft — deferred until we measure first-index latency against a real repo.
- **Alternative: `supergateway --outputTransport streamableHttp --stateful`.** Not validated. If the custom multiplexer turns into a maintenance burden, revisit this path with a focused concurrency test.
- **Auth.** Sidecar binds `127.0.0.1` only. If we ever need non-loopback exposure, revisit.
