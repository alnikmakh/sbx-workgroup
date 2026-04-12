# Phase 05 — Role templates & examples

## Purpose

Content-only phase. Ship sensible defaults so users can run `workgroup up examples/feature-x.yaml` on day one without authoring any role content. Can be worked on in parallel with any other phase; doesn't block them.

## Scope

### `workgroup/templates/roles/planner.md`

~30 lines. Structure:

1. **Identity line** (first paragraph): "You are the **planner** agent in a sbx workgroup." — explicit role name, first paragraph. This is what `/clear` + "what is your role?" must recover.
2. **Bridge cheatsheet**:
   - `$BRIDGE_DIR`, `$AGENT_ID`, `$AGENT_PEERS_OUT`, `$AGENT_PEERS_IN` — what they mean.
   - `bridge-send --to <peer> --kind plan --file <path> --subject <text>` with a literal example.
   - `bridge-recv` to list inbox; `bridge-recv --pop <id>` to read a message and mark it processed.
3. **Responsibilities**: produce plans in markdown, hand off to the first peer in `$AGENT_PEERS_OUT` (normally `reviewer`), respond to feedback from `$AGENT_PEERS_IN`.
4. **Handoff recipe**:
   ```
   1. Draft plan to a temporary file (e.g., Write tool).
   2. bridge-send --to "$(echo "$AGENT_PEERS_OUT" | cut -d, -f1)" --kind plan --file <path> --subject "<short>"
   3. Tell the user the signal id you just sent.
   ```
5. **Reminder**: "This role is in your system prompt; `/clear` does not wipe it."

### `workgroup/templates/roles/reviewer.md`

Same shape. Responsibilities: read incoming plans from `bridge-recv`, critique, produce a `report` kind message, send back to the plan's author AND forward to the next peer (executor) if approved.

Recipe:

```
1. bridge-recv          # list pending inbox
2. bridge-recv --pop <id>   # read the plan
3. Write a report file, critique + decision (approve/revise/reject).
4. bridge-send --to <original-author> --kind report --file <path> --subject "review: <plan subject>"
5. If approved and executor is in $AGENT_PEERS_OUT:
   bridge-send --to executor --kind plan --file <original plan> --subject "approved: <subject>"
```

### `workgroup/templates/roles/executor.md`

Responsibilities: read approved plans, carry them out against the worktree, report progress and blockers back to reviewer/planner.

Recipe:

```
1. bridge-recv --pop <id>   # get the plan
2. Implement in the worktree you're already cd'd into.
3. bridge-send --to reviewer --kind report --file <path> --subject "executed: <subject>"
```

Explicitly mentions: "You are cd'd into a dedicated git worktree. Treat it as your sandbox."

### Role file constraints

- Every role file MUST name the role in its first paragraph (role persistence test depends on this).
- Every role file MUST mention `bridge-send`, `bridge-recv`, and reference `$AGENT_PEERS_OUT` / `$AGENT_PEERS_IN`.
- Role files SHOULD NOT assume specific peer names — always go through the env vars. (The manifest is the source of truth for topology.)

### `examples/feature-x.yaml`

The canonical 3-agent example:

```yaml
name: feature-x
worktree:
  branch: wg/feature-x
  base: main
agents:
  - id: planner
    role: planner
  - id: reviewer
    role: reviewer
  - id: executor
    role: executor
edges:
  - planner -> reviewer
  - reviewer -> planner
  - reviewer -> executor
  - executor -> reviewer
layout: tiled
```

### `examples/pair.yaml`

Minimal 2-agent example:

```yaml
name: pair
worktree:
  branch: wg/pair
agents:
  - id: planner
    role: planner
  - id: executor
    role: executor
edges:
  - planner -> executor
  - executor -> planner
layout: even-horizontal
```

### `examples/feature-a.yaml` and `examples/feature-b.yaml`

Two minimal, distinct workgroups used by Phase 06's parallel-isolation test. Identical shape to `pair.yaml` but with different `name` and `branch` values so two can run concurrently without collision:

```yaml
# examples/feature-a.yaml
name: feature-a
worktree:
  branch: wg/feature-a
agents:
  - id: planner
    role: planner
  - id: executor
    role: executor
edges:
  - planner -> executor
  - executor -> planner
layout: even-horizontal
```

```yaml
# examples/feature-b.yaml
name: feature-b
worktree:
  branch: wg/feature-b
agents:
  - id: planner
    role: planner
  - id: executor
    role: executor
edges:
  - planner -> executor
  - executor -> planner
layout: even-horizontal
```

### `examples/bad-edges.yaml`

Intentionally broken manifest for verification step 6 in Phase 04:

```yaml
name: bad-edges
agents:
  - id: planner
    role: planner
edges:
  - planner -> ghost        # ghost is not declared
```

## Inputs

None beyond the contracts in `00-overview.md` and `04-workgroup-cli.md`.

## Outputs / contracts published

Default role content + canonical examples referenced by the README and by Phase 06's smoke test.

## Verification

1. Every file under `workgroup/templates/roles/` names its role in the first paragraph (grep check).
2. Every role file mentions `bridge-send` and `bridge-recv`.
3. `workgroup up examples/feature-x.yaml` and `examples/pair.yaml` both succeed.
4. `workgroup up examples/bad-edges.yaml` exits non-zero with "edge planner->ghost: ghost is not a declared agent".
5. Post-`/clear` "what is your role?" answers correctly in each example (also part of Phase 06).

## Open items

- Tone of role files (terse vs verbose). Starting: terse — ~30 lines each, recipe-driven. Expand only if agents in practice need more hand-holding.
- Whether to ship an `architect.md` / `qa.md` / etc. beyond the initial three. Deferred until the first three are validated in a real run.
