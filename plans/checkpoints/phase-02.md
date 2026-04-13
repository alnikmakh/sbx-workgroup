# Phase 02 checkpoint — Per-project MCP sidecar (multiplexer + cgc)

Status: **implemented and in continuous use** since 2026-04-12. Written up
retroactively after Phases 01/03/04/05 had already leaned on the sidecar.

Date: 2026-04-13 (retroactive).

## What was built

| File | Role |
|---|---|
| `sbx/host-mcp/Dockerfile.sidecar` | Python 3.12 slim + `codegraphcontext[falkordb]` + starlette/uvicorn; copies `mcp_mux.py` to `/opt/mcp_mux.py`; `ENTRYPOINT python3 /opt/mcp_mux.py`; `EXPOSE 8811`. |
| `sbx/host-mcp/mcp_mux.py` | 346-line asyncio multiplexer. PID 1 of the sidecar container. Owns exactly one long-lived `cgc mcp start` child; rewrites JSON-RPC ids and `_meta.progressToken`s to fan N MCP HTTP sessions onto a single stdio backend. Serves streamable HTTP at `/mcp` and a `/health` probe. |
| `sbx/host-mcp/sidecar-up.sh` | 105-line lifecycle: loads `machine.yaml`, computes hashed port (`8000 + crc32(project) mod 1000`, with `port_overrides:` escape hatch), labels container `sbx.project=<project>`, binds `127.0.0.1:<port>:8811`, mounts `${projects_root}/<project>:/work:ro` and `${cgc_data_root}/<project>:/root/.cgc`, waits for `/health`, prints the port on stdout. Idempotent. |
| `sbx/host-mcp/sidecar-down.sh` | 26-line teardown: `docker stop` + `docker rm` by label. Exit 0 if already gone. Does not touch `${cgc_data_root}/<project>/`. |
| `sbx/host-mcp/build.sh` | `docker build -t sbx-cgc-sidecar:local -f Dockerfile.sidecar .`. Called manually or auto-triggered by `sidecar-up.sh` if the image is missing. |

Total: 510 lines across Python + shell + Dockerfile.

Built under commit `6e0992d` ("phase 02"). No code changes in any later phase.

## Divergences from `plans/02-mcp-gateway.md`

1. **`/health` endpoint added beyond the plan.** The plan only specified
   `/mcp`. `sidecar-up.sh` needs a cheap synchronous probe to bound the
   readiness wait, and Phase 01 / Phase 04's `postinstall.sh` also uses it
   from inside the sandbox. `/health` returns
   `{"ok": true, "project": "<name>", "sessions": <N>}` — the session count
   is a useful side signal that's since become load-bearing for concurrency
   sanity checks (see §Verification §5).

2. **Image tag is fully project-agnostic.** The plan allowed per-project
   build-time customization; in practice nothing needs it, so the image is
   a pure singleton (`sbx-cgc-sidecar:local`) and every project-specific
   parameter arrives via `-e MUX_PROJECT=<name>` / bind mounts. Keeps
   `build.sh` a one-liner.

3. **Notification routing is still broadcast.** The plan flagged this as an
   open item ("revisit once we see real cgc traffic under load"). After
   Phases 03/04 brought the sandbox into daily use, broadcast has not caused
   observable problems — no per-session notifications from cgc have been
   spotted so far. Keeping it broadcast until a concrete failure motivates
   a rewrite.

4. **Progress token rewriting is implemented.** The plan listed this as
   "defer until the first request/response path is working." It's in
   `mcp_mux.Mux.progress_map` and tested implicitly by every tool call that
   passes a `_meta.progressToken`.

5. **Sidecar lifetime isn't bound to `sbx rm`.** `teardown.sh` (Phase 01)
   calls `sidecar-down.sh` explicitly, but if the user `sbx rm`s the
   sandbox manually, the sidecar lingers. Same as the plan; worth noting
   as a known foot-gun.

## Verification

Every item from `plans/02-mcp-gateway.md` §Verification. The sidecar has been
running continuously since 2026-04-12 and served every Phase 03/04/05 check
in this repo, so most items are verified by the fact that later phases
passed. Concrete evidence captured on 2026-04-13:

| # | Check | Evidence |
|---|---|---|
| 1 | `build.sh` builds the image | ✅ `sbx-cgc-sidecar:local` present (`docker image inspect`). |
| 2 | `sidecar-up.sh sbx` → port in 8000–8999, `docker ps` shows container | ✅ Port `8560` = `8000 + crc32("sbx") mod 1000`, container `cgc-sidecar-sbx` up for 10+ hours. |
| 3 | `curl /health` answers | ✅ `{"ok":true,"project":"sbx","sessions":7}`. |
| 4 | Re-run `sidecar-up.sh` is a no-op that prints the same port | ✅ `provision.sh` re-run today hit the idempotent branch and picked up port `8560`. |
| 5 | Concurrency: two concurrent MCP clients, exactly one cgc child | ✅ `docker top cgc-sidecar-sbx` shows a single `cgc mcp start` child (PID tree: `mcp_mux` PID 1 → one `cgc mcp start` → one `falkor_worker` → one `redis-server`). `/health` reports `sessions: 7`, which means at least seven concurrent MCP sessions have coexisted against that single cgc child without tripping the JSON-RPC id mux. |
| 6 | Kill cgc child → mux respawns, in-flight fails cleanly, next call succeeds | ⏸ not re-verified today; asserted by implementation (`Mux._run_backend_forever` loop + bounded restart budget) and by the fact that the sidecar has been up 10+ hours without the container itself restarting. Worth a targeted test during Phase 06. |
| 7 | `sidecar-down.sh sbx` exits 0, container gone, data dir preserved | ✅ Phase 01 teardown path exercises this and preserves `${cgc_data_root}/sbx/`. |
| 8 | After down/up, a previously indexed query returns the same data without reindexing | ⏸ not yet demonstrated end-to-end. cgc has not been instructed to index `/work` in this project yet — see Phase 06 §13. |
| 9 | From inside the VM: `curl /mcp`, `claude mcp list` shows `cgc` Connected, a tool call returns | ✅ `claude mcp list` → `cgc: http://host.docker.internal:8560/mcp (HTTP) - ✓ Connected`, verified today. Live tool call from a role-injected pane is Phase 06 §10. |

Items 6 and 8 are the only ones not covered today — both depend on Phase 06
smoke coverage, not on Phase 02 code changes.

## Operational notes learned in later phases

1. **Hostname inside the sandbox is `host.docker.internal`, not
   `127.0.0.1:8811`.** Phase 01's "ports publish" assumption doesn't match
   the real `sbx` CLI, so the guest-side registration URL ended up being
   `http://host.docker.internal:<hashed-port>/mcp`. This is documented in
   Phase 01's checkpoint; Phase 02 itself is unaffected (container is still
   reached via `127.0.0.1:<hashed-port>` from the host, and the multiplexer
   inside the container still listens on `0.0.0.0:8811`).

2. **The Balanced sbx policy hides the sidecar by default.**
   `provision.sh` must add `sbx policy allow network localhost:<port>`
   before the sandbox's outbound HTTP proxy will route `host.docker.internal`
   requests to it. Owned by Phase 01's `ensure_policy`.

3. **`ANTHROPIC_API_KEY=proxy-managed` in the sandbox pid-1 env would trick
   `claude` into rejecting its OAuth creds when talking to the sidecar.**
   This is a sbx-side behaviour, not an MCP one, but it bit the first
   real workgroup pane launch. Phase 04's `tmux.sh` now `unset`s it before
   exec'ing `claude`. Mentioned here because the symptom first looked like
   an MCP issue.

## Deferred / follow-ups

1. **Targeted chaos test** — kill `cgc mcp start` inside the container and
   assert `mcp_mux` respawns it, in-flight requests receive
   `-32000 "backend crashed"`, and the next request succeeds. The code path
   is there (`Mux._run_backend_forever`, `restart_times` budget); it has not
   been exercised under test. Worth adding to Phase 06's smoke script.

2. **Down/up data survival** — run a cgc query that returns real indexed
   data, `sidecar-down.sh`, `sidecar-up.sh`, re-run the same query, assert
   identical result. Checklist item #8. Blocked only on having a real
   indexed corpus in `${cgc_data_root}/sbx/`, which Phase 06 will arrange.

3. **Sidecar lifecycle vs. `sbx rm`** — if the user manually removes the
   sandbox without running `teardown.sh`, the sidecar is orphaned. Low
   priority; document in the README or add a `sbx ls`-based reaper in
   `sidecar-up.sh`. Not blocking.

4. **Notification routing = broadcast** — still an open item from the plan.
   Revisit when cgc actually emits session-scoped notifications.

5. **`cgc.index /work`** — no phase in 00–05 needs indexed data; Phase 06
   will be the first user. Once the smoke test runs `cgc.index` once, later
   runs can assume the DB is populated.

## Files touched this checkpoint

Created:
- `plans/checkpoints/phase-02.md` (this file).

Not modified: Phase 02 source (`sbx/host-mcp/*`) — retroactive checkpoint,
no code changes needed.
