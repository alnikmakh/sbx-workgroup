# Phase 03 checkpoint — Bridge protocol & helpers

Status: **implemented and verified** on the dev container (32/32 checks pass,
step 8 still skipped locally — now covered by a shim-based teardown test, 8b).

Date: 2026-04-13.

## Amendment — bridge-watch signal-handling bug

In-sandbox verification caught a real bug the initial review missed:
`workgroup/bin/bridge-watch` used `inotifywait ... | while read` in a pipeline.
Pipeline stages run in subshells, so `trap 'exit 0' TERM` in the parent never
reached `inotifywait`, and killing the shell PID left `inotifywait` running —
step 8 hung forever inside the sandbox.

**Fix:** run `inotifywait` as a backgrounded child writing into a named FIFO,
read from the FIFO in the main shell, and install a cleanup trap that kills the
recorded `$IW_PID` explicitly:

```
mkfifo "$FIFO"
inotifywait ... > "$FIFO" &
IW_PID=$!
trap 'kill $IW_PID 2>/dev/null; rm -f "$FIFO"' EXIT
trap 'exit 0' TERM INT
while read -r dir fname; do ...; done < "$FIFO"
```

Both the PID and the read loop now live in the same shell, so SIGTERM actually
tears the whole thing down.

**New regression test: step 8b** — a fake `inotifywait` shim that emits one line
and then `exec sleep 3600`, prepended to `$PATH`. The test backgrounds
`bridge-watch`, sends SIGTERM, and asserts three things within a 3s deadline:
(1) the watcher shell exits, (2) the shim child is reaped (not orphaned),
(3) the pre-kill event line made it to stdout. This is the exact failure mode
the in-sandbox run hit, and it reproduces locally without real inotify. 32/32
pass now.

Step 8 (real `inotifywait`) remains `SKIP` in the dev container. It should
still be rerun inside the sandbox as part of Phase 04 bring-up — the shim test
exercises the signal-handling path but not the kernel-side event delivery.


## What was built

| File | Role |
|---|---|
| `workgroup/lib/bridge.sh` | POSIX sh library: `bridge_init`, `bridge_load`, `bridge_topology_allows`, `bridge_next_signal_id`, `bridge_atomic_write`, `bridge_archive_signal`, plus `bridge_path` helper. |
| `workgroup/bin/bridge-init`  | `bridge-init <name> --agents a,b --edges "a->b"` — thin wrapper; idempotent. |
| `workgroup/bin/bridge-send`  | `--to --kind --file [--subject]`. Edge-checked, atomic write, prints signal id on stdout. |
| `workgroup/bin/bridge-recv`  | Listing with `--kind`/`--from` filters; `--pop <id>` prints payload and archives the signal. |
| `workgroup/bin/bridge-peek`  | `exec`s `bridge-recv` with no args — non-destructive full listing. |
| `workgroup/bin/bridge-watch` | `inotifywait -mrq` on `inbox/`, emits one line per signal, exits cleanly on SIGTERM. |
| `workgroup/test-bridge.sh`   | Phase 03 verification suite (9 steps / 29 assertions). |

The reference harness at `.tmp/bridge-harness/` (from Phase 03 planning) is
superseded by the above; left in place for history.

## Design reminders (all from the plan, restated here for future-me)

- **No fsync.** Same-FS `rename(2)` is atomic; in-flight `.tmp.<pid>` files use a
  dot prefix so `*.json` globs never see a partial write. Dropping fsync keeps
  the helpers pure shell + `jq` + `flock`.
- **Signal id format:** `<UTC>-<agent>-<seq>` where `<seq>` is a 3-digit
  per-agent counter under `flock` on `state.json.lock`. Sortable, readable, no
  UUID dep.
- **`--pop` semantics:** payload files in `plans/`/`reports/`/`notes/` are shared
  history and stay put; only the signal JSON moves from `inbox/<me>/` to
  `archive/`. Matches the plan's "Frozen v1 decisions".
- **Idempotency:** `bridge_init` re-called with the same agent set is a no-op;
  re-called with a different agent set exits non-zero. Tested.
- **Testability hook:** `$BRIDGE_ROOT` (default `/bridge`) lets the test suite
  point at a scratch `mktemp -d` instead of touching the real mount.

## Verification results

`workgroup/test-bridge.sh` covers the full verification matrix from
`plans/03-bridge-protocol.md` §"Verification":

| Plan check | Test step | Result |
|---|---|---|
| 1. `bridge-init` creates tree + state.json | [1] | ✅ (12 sub-checks) |
| — (extra) re-init idempotency | [2] | ✅ |
| — (extra) re-init mismatch rejected | [3] | ✅ |
| 2. `jq .agents state.json` | [1] | ✅ |
| 3. `bridge-send` exits 0 and prints id | [4] | ✅ |
| 4. signal in `inbox/b/`, audit in `outbox/a/`, payload in `notes/` | [4] | ✅ |
| 5. `bridge-recv` lists the signal | [5] | ✅ |
| 6. `bridge-recv --pop <id>` prints payload, archives signal | [6] | ✅ |
| 7. undeclared edge rejected | [7] | ✅ |
| 8. `bridge-watch` captures event within 1s | [8] | ⏸ skipped — `inotifywait` not installed in this dev container. In the sbx sandbox it is installed by `workgroup/etc/postinstall.sh` (already lists `inotify-tools`). The test auto-skips with `command -v inotifywait` and will run inside the sandbox. |
| 9. concurrent 10× send, distinct ids, no `.tmp` leftovers, all valid JSON | [9] | ✅ |

Final tally: `passed: 29    failed: 0` (step 8 skipped).

## Known limitations / follow-ups (not blocking Phase 03)

1. **`bridge-watch` on real inotify.** Fixed after in-sandbox verification found
   a signal-handling bug (see Amendment above). Shim-based teardown test now
   runs locally as step 8b. Kernel-side event delivery (real `inotifywait`)
   still needs to be rerun inside the sandbox during Phase 04 bring-up.
2. **`date -u -d <iso>` in `bridge-recv`.** Uses GNU coreutils. BusyBox `date`
   doesn't parse ISO-8601; if we ever target Alpine for the sandbox, the age
   column needs a fallback. Ubuntu sbx template is GNU — fine for v1.
3. **`bridge-load` is exported but unused** by Phase 03 itself; Phase 04's
   `workgroup up` is its first consumer. Kept in because the plan lists it.
4. **`state.json` fields `worktree` and `branch`** are not written by
   `bridge_init` — Phase 04 (`workgroup up`) is the authority on those, per the
   plan's state.json schema. `bridge_init` only writes `name`/`created_at`/
   `agents`/`edges`.

## Environment dep learned the hard way

The dev container (this working directory) does **not** have `jq` or
`inotify-tools` in its base image; I fetched the static `jq` binary into
`~/.local/bin/jq` to run the tests. Production sandboxes get both via
`workgroup/etc/postinstall.sh`. If future phases add more shell tools, keep this
in mind — local test runs need a one-time jq bootstrap.

## Files touched this checkpoint

Created:
- `workgroup/lib/bridge.sh`
- `workgroup/bin/bridge-init`
- `workgroup/bin/bridge-send`
- `workgroup/bin/bridge-recv`
- `workgroup/bin/bridge-peek`
- `workgroup/bin/bridge-watch`
- `workgroup/test-bridge.sh`
- `plans/checkpoints/phase-03.md` (this file)

Not modified: `plans/03-bridge-protocol.md` (implementation matched the plan as
written; no divergences worth back-porting).
