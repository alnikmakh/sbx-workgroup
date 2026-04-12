# Phase 03 — Bridge protocol & helpers

## Purpose

Define the filesystem contract for agent-to-agent messaging and ship the small helper commands agents use to read and write it. Completely independent of tmux, Claude, and the MCP stack — the whole phase is unit-testable with plain shell.

## Scope

### Directory layout under `/bridge/<name>/`

(Mirrored from `00-overview.md` — this phase is the authority.)

```
/bridge/<name>/
├── state.json
├── state.json.lock             # flock target
├── .counters/<agent-id>        # per-agent monotonic counter
├── roles/<agent-id>.md
├── plans/<id>.md
├── reports/<id>.md
├── notes/<id>.md
├── inbox/<agent-id>/<id>.json
├── outbox/<agent-id>/<id>.json
└── archive/<id>.json
```

Allowed `kind` values: `plan`, `report`, `note` (matches `plans/`, `reports/`, `notes/`). `bridge-send` rejects any other kind.

`/bridge/_archive/<name>-<UTC>/` is produced by Phase 04's `workgroup down`; this phase doesn't touch it.

### `state.json` schema

See `00-overview.md` for the canonical shape. This phase owns the helpers that read and mutate it. All mutations go through `flock /bridge/<name>/state.json.lock` so concurrent `bridge-send` calls can't corrupt it.

### Signal JSON schema

See `00-overview.md`. Signal IDs use the format `<UTC>-<agent>-<seq>` where `<seq>` is a 3-digit per-agent counter maintained in `/bridge/<name>/.counters/<agent>`. Rationale: sortable, readable, avoids UUID dependency.

### Atomic write helper

All signal writes go:

1. Write payload bytes to `inbox/<to>/.<id>.json.tmp` (dot-prefixed so listers ignore it).
2. `mv` (atomic rename on same filesystem) to `inbox/<to>/<id>.json`.

No `fsync`. Rationale: the bridge lives on a host bind-mounted ext4 directory; POSIX `rename(2)` on the same filesystem gives atomic visibility — a reader either sees the old name or the new name, never a partial file. `fsync` would only buy *durability* on host kernel crash, and losing an in-flight signal to a crash is not a correctness concern for v1 (sender can resend; receiver's state is idempotent). Dropping `fsync` also avoids the shell portability mess (`dd conv=fsync` is awkward for 200 B files; `python3 -c 'import os;os.fsync(...)'` adds a Python dep inside the VM).

The dot-prefix is load-bearing: `bridge-recv`'s inbox listing must glob `*.json` (not `.*`) so an in-flight `.tmp` file is never reported to the agent.

Receivers only see fully-written signals; partial writes never appear in the inbox.

### `lib/bridge.sh` — shared shell library

Functions (sourced by the helper commands):

- `bridge_init <name> --agents a,b,c --edges "a->b,b->c"` — create the full directory tree under `/bridge/<name>`, write `state.json`. Idempotent: refuses if `/bridge/<name>` already exists with a different agent set.
- `bridge_load <name>` — read `state.json`, export convenience variables (`BRIDGE_STATE_AGENTS`, `BRIDGE_STATE_EDGES`) into the current shell.
- `bridge_topology_allows <name> <from> <to>` — exit 0 if the edge `from -> to` is declared, non-zero otherwise.
- `bridge_next_signal_id <name> <agent>` — bump counter under `flock`, return `<UTC>-<agent>-<seq>`.
- `bridge_atomic_write <dest_file> < input` — write + sync + rename.
- `bridge_archive_signal <name> <agent> <signal_id>` — move a signal from `inbox/<agent>/` to `archive/`.

### CLI helpers (`workgroup/bin/`)

All helpers read `$BRIDGE_DIR` and `$AGENT_ID` from the environment (set by Phase 04 at pane launch). They derive the workgroup name from `$BRIDGE_DIR`.

#### `bridge-init <name> --agents a,b,c --edges "a->b,b->c"`

Thin wrapper over `bridge_init`. Intended to be called by Phase 04's `workgroup up`, but also usable from the shell for tests.

#### `bridge-send --to <agent> --kind <plan|report|note> --file <path> [--subject <text>]`

Steps:

1. Require `$BRIDGE_DIR`, `$AGENT_ID`. Error clearly if missing.
2. `bridge_topology_allows` — reject with a non-zero exit and a message naming the missing edge if the send isn't authorized.
3. Generate signal id via `bridge_next_signal_id`.
4. Copy `--file` into `$BRIDGE_DIR/<kind-dir>/<id>.<ext>` (`.md` default).
5. Compose signal JSON (id, from, to, kind, payload, subject, created_at).
6. Write signal atomically into `$BRIDGE_DIR/inbox/<to>/<id>.json`.
7. Also write a copy to `$BRIDGE_DIR/outbox/<AGENT_ID>/<id>.json` for audit.
8. Print the signal id on stdout so callers can reference it.

#### `bridge-recv [--kind <k>] [--from <agent>] [--pop <id>]`

Without `--pop`: list signals in `$BRIDGE_DIR/inbox/$AGENT_ID/`, optionally filtered by kind/from, as a table (id, from, kind, subject, age).

With `--pop <id>`: print the payload file's content to stdout and move the signal to `$BRIDGE_DIR/archive/`. The payload file itself stays in `plans/`/`reports/`/`notes/` — only the signal is archived. (Rationale: payloads are shared history; signals are per-receiver.)

#### `bridge-peek`

Non-destructive `bridge-recv` — same output as the no-`--pop` form but always full listing.

#### `bridge-watch <name>`

Runs `inotifywait -mrq -e create,moved_to /bridge/<name>/inbox` and prints one line per event:

```
2026-04-12T10:15:04Z NEW reviewer <- planner: plan "Initial plan for OAuth refactor"
```

Intended to run in its own tmux window (the `watch` window created by Phase 04). Exits cleanly on SIGTERM so `workgroup down` can kill it by closing the window.

## Inputs (from Phase 01)

- `inotify-tools`, `jq`, `flock` installed.
- `/bridge` mount exists.

## Outputs / contracts published

- Stable on-disk layout under `/bridge/<name>/`.
- `state.json` schema that Phase 04 writes and these helpers read.
- `bridge-*` commands on PATH, used by Phase 04 at `up` time and by agents at runtime.
- `lib/bridge.sh` functions, sourced by any shell caller in the project.

## Verification (shell-level, no Claude required)

1. `bridge-init test-wg --agents a,b --edges "a->b"` creates `/bridge/test-wg/{state.json,inbox/{a,b},outbox/{a,b},plans,reports,notes,archive,roles,.counters}`.
2. `jq .agents /bridge/test-wg/state.json` returns `[{"id":"a",...},{"id":"b",...}]`.
3. In shell 1: `echo "hi" > /tmp/hi.md && BRIDGE_DIR=/bridge/test-wg AGENT_ID=a bridge-send --to b --kind note --file /tmp/hi.md --subject "ping"` — exits 0 and prints an id.
4. `ls /bridge/test-wg/inbox/b/` contains the signal. `ls /bridge/test-wg/outbox/a/` contains the audit copy. `ls /bridge/test-wg/notes/` contains the payload.
5. `BRIDGE_DIR=/bridge/test-wg AGENT_ID=b bridge-recv` lists the signal with kind/from/subject.
6. `BRIDGE_DIR=/bridge/test-wg AGENT_ID=b bridge-recv --pop <id>` prints `hi`, moves signal to `archive/`.
7. `BRIDGE_DIR=/bridge/test-wg AGENT_ID=b bridge-send --to a ...` exits non-zero with `no edge b->a`.
8. In shell 2: `bridge-watch test-wg` — when the send in step 3 runs, a `NEW` line appears within a second.
9. Concurrent stress: run 10 `bridge-send` calls in parallel from the same agent; confirm 10 distinct signal ids and all 10 payloads land.

## Frozen v1 decisions

- **Signal ID format:** `<UTC>-<agent>-<seq>` (3-digit seq, per-agent counter). Sortable, readable, no UUID dep. Revisit only if we need unguessable ids.
- **Payload lifecycle on `--pop`:** payload file stays in `plans/`/`reports/`/`notes/` (shared history); only the signal JSON moves to `archive/`.
- **Durability:** no `fsync`; same-FS rename provides atomic visibility, which is all v1 needs (see "Atomic write helper" above).
- **`bridge-recv` default output:** human-readable table. `--json` is a future addition, not v1.

## Open items

- None blocking. All Phase 03 ambiguities resolved 2026-04-12; see `.tmp/bridge-harness/` for the reference shell harness that exercises the contracts above.
