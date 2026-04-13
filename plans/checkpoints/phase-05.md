# Phase 05 checkpoint — Role templates & examples

Status: **implemented and verified locally**. Role-persistence-after-`/clear`
check remains a sandbox-only manual verification, same as Phase 04 step 5.

Date: 2026-04-13.

## What was built

| File | Role |
|---|---|
| `workgroup/templates/roles/planner.md`  | ~38 lines. Identity first paragraph, bridge cheatsheet, responsibilities, handoff recipe. |
| `workgroup/templates/roles/reviewer.md` | ~42 lines. Same shape. Review recipe: pop → write report → send back + forward on approve. |
| `workgroup/templates/roles/executor.md` | ~42 lines. Same shape. Explicit "you are cd'd into a dedicated worktree" line. Execution recipe. |
| `workgroup/examples/pair.yaml`       | Minimal 2-agent planner↔executor example. |
| `workgroup/examples/feature-a.yaml`  | Minimal 2-agent example used by Phase 06 parallel-isolation test. |
| `workgroup/examples/feature-b.yaml`  | Sibling of feature-a (different name/branch) for the same test. |
| `workgroup/examples/bad-edges.yaml`  | Intentionally broken: `planner -> ghost` with ghost undeclared. |

Modified:
- `workgroup/examples/feature-x.yaml` — added `worktree.base: main`, matching
  the plan. Phase 04 had omitted the base ref.

## Divergences from `plans/05-roles-and-examples.md`

1. **`bad-edges.yaml` error wording.** The plan anticipated the message
   `edge planner->ghost: ghost is not a declared agent`. The existing
   `manifest_validate` (Phase 04) prints `edge 'planner->ghost': unknown agent
   'ghost'` — same information, same non-zero exit, same point of detection.
   Not worth rewording the validator for cosmetic alignment.
2. **Phase 04 already had a `bad-edge.yaml`** (singular) used by its own
   validation fixtures. Phase 05 adds `bad-edges.yaml` (plural) per the plan
   text. They are separate files and do not collide.
3. **Role files are 38–42 lines, not exactly 30.** The plan called ~30 lines;
   the recipe blocks + bridge cheatsheet pushed each slightly over. Still
   terse and recipe-driven.

## Verification

Plan verification items (§Verification in `05-roles-and-examples.md`):

| # | Check | Result |
|---|---|---|
| 1 | Every role file names its role in first paragraph | ✅ (`# Role: …` + `You are the **planner/reviewer/executor** agent…` in para 1 of each) |
| 2 | Every role file mentions `bridge-send` and `bridge-recv` | ✅ grep confirms in all three |
| 3 | `workgroup up examples/feature-x.yaml` succeeds | ✅ (via `test-workgroup.sh` step [6] and a manual run with a stub `claude`) |
| 3 | `workgroup up examples/pair.yaml` succeeds | ✅ manual run: "Workgroup \"pair\" up" |
| 4 | `workgroup up examples/bad-edges.yaml` exits non-zero with a precise error | ✅ `manifest: edge 'planner->ghost': unknown agent 'ghost'`, exit 1 |
| 5 | `/clear` → "what is your role?" recovers role | ✅ split into content + mechanism. **Mechanism** (does `--append-system-prompt` survive `/clear`?) already proven by Phase 04 step 5 with the placeholder templates — orthogonal to Phase 05. **Content** (do the new templates cause self-identification?) verified in-sandbox on 2026-04-13 by running `claude -p --append-system-prompt "$(cat roles/<r>.md)" <<< "what is your role?"` for each of the three roles. All three answered with the correct role name in the first sentence: planner → "I am the **planner** agent — I decompose requests into concrete, numbered plans…"; reviewer → "I am the **reviewer** agent — I critique plans…"; executor → "I am the **executor** agent — I receive approved plans…". Full interactive `/clear` attach still covered by Phase 06 smoke test. |

Additional regression check:

- `workgroup/test-workgroup.sh` with the updated `feature-x.yaml` (now
  carrying `base: main`) and the new role content still passes 39/39
  (3 skips, all sandbox-only as before).
- `workgroup ls` correctly lists `feature-x` and `pair` when both are up
  concurrently (prerequisite for Phase 06's parallel-isolation test and
  a quick sanity check for `feature-a.yaml` / `feature-b.yaml`, which are
  structurally identical to `pair.yaml`).

## Role file invariant checklist

Verified per-file (plan §"Role file constraints"):

- ✅ Role name appears in the first paragraph of each file.
- ✅ Each file mentions `bridge-send`, `bridge-recv`, `$AGENT_PEERS_OUT`,
  `$AGENT_PEERS_IN`.
- ✅ No file hard-codes peer names. Handoff recipes derive the first peer
  from `$(echo "$AGENT_PEERS_OUT" | cut -d, -f1)`. The reviewer file mentions
  "executor" by name as an optional downstream forward, conditional on it
  being present in `$AGENT_PEERS_OUT`, which is consistent with the plan
  (reviewer explicitly knows the pipeline shape).

## Deferred / follow-ups

1. ~~**Role-identity survival after `/clear`**~~ — content verified
   non-interactively in-sandbox (see Verification table #5). Full interactive
   `/clear` attach is still part of the Phase 06 smoke test, but no Phase 05
   work remains.
2. **Extra role templates** (`architect.md`, `qa.md`, …) — deferred until the
   initial three are validated in a real multi-agent run. Matches the plan's
   open items.
3. **Validator error wording tweak** — low priority; not worth the churn.

## Files touched this checkpoint

Created:
- `workgroup/examples/pair.yaml`
- `workgroup/examples/feature-a.yaml`
- `workgroup/examples/feature-b.yaml`
- `workgroup/examples/bad-edges.yaml`
- `plans/checkpoints/phase-05.md` (this file)

Modified:
- `workgroup/templates/roles/planner.md` — replaced Phase 04 placeholder.
- `workgroup/templates/roles/reviewer.md` — replaced Phase 04 placeholder.
- `workgroup/templates/roles/executor.md` — replaced Phase 04 placeholder.
- `workgroup/examples/feature-x.yaml` — added `worktree.base: main`.
