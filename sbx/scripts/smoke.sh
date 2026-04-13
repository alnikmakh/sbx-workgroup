#!/usr/bin/env bash
# smoke.sh <project> — end-to-end smoke test for Phases 01–05.
#
# Automates the Claude-free parts of plans/06-verification.md:
#   §0  sidecar primitives
#   §1  host provisioning (idempotent re-run)
#   §2  inside-VM sanity
#   §4  bridge primitives (via /opt/workgroup/test-bridge.sh)
#   §5  manifest validation (via /opt/workgroup/test-workgroup.sh)
#   §6  happy path              (ditto)
#   §11 teardown archive        (ditto)
#   §12 parallel isolation (feature-a + feature-b concurrent)
#
# Manual / Claude-dependent bits are deliberately out of scope:
#   §7  role persistence across /clear
#   §8  bridge happy path through claude
#   §9  topology enforcement through claude
#   §10 cgc tool use from a role-injected pane
#   §13 VM rebuild preserves cgc index (too destructive for a smoke run)
#
# Exit 0 on full pass; non-zero with a summary on first failure.
# All diagnostics go to stderr; stdout is a clean pass/fail tally.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"

project="${1:-}"
[ -n "$project" ] || { printf 'usage: smoke.sh <project>\n' >&2; exit 2; }

vm="sbx-$project"
pass=0
fail=0
failures=()

note() { printf '[smoke] %s\n' "$*" >&2; }
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1" >&2; }
nope() {
    fail=$((fail+1))
    failures+=("$1")
    printf '  FAIL %s\n' "$1" >&2
    if [ "${SMOKE_FAIL_FAST:-1}" = 1 ]; then
        summary
        exit 1
    fi
}
section() { printf '\n[smoke] %s\n' "$*" >&2; }

summary() {
    printf '\n[smoke] passed: %d    failed: %d\n' "$pass" "$fail" >&2
    if [ "$fail" -gt 0 ]; then
        printf '[smoke] failures:\n' >&2
        for f in "${failures[@]}"; do printf '  - %s\n' "$f" >&2; done
    fi
}

# Each `sbx exec` auto-starts the sandbox and sbx stops it again when the
# command returns. Rapid-fire exec calls race against that stop cycle and
# surface as "container not running" errors. Consolidate in-sandbox work
# into as few exec calls as possible; for multi-assertion batches, use
# `in_sbx_batch` which runs a heredoc script in one shot and parses
# TOKEN-separated results out of its stdout.
in_sbx() { sbx exec "$vm" -- bash -lc "$1"; }

# Wait for the sandbox to reach a stable stopped state. sbx exec starts the
# sandbox, runs the command, then async-stops it; a second exec issued while
# that stop is still pending gets killed ~10s in. Poll until sbx ls reports
# "stopped" and the status has been stable for a moment, then proceed.
wait_for_sandbox_stopped() {
    local max_attempts=30
    local i=0
    while [ $i -lt $max_attempts ]; do
        local status
        status=$(sbx ls 2>/dev/null | awk -v n="$vm" '$1==n {print $3; exit}')
        if [ "$status" = "stopped" ]; then
            return 0
        fi
        sleep 1
        i=$((i+1))
    done
    return 1
}

in_sbx_batch() {
    # $1 = script body. Script must print lines of the form
    # "RESULT <ok|fail> <label>" for each assertion.
    local script="$1"
    local out
    out=$(mktemp)
    sbx exec "$vm" -- bash -lc "$script" >"$out" 2>&1 || true
    if [ "${SMOKE_DEBUG:-0}" = 1 ]; then
        printf '[smoke-debug] raw batch output (%d bytes):\n' "$(wc -c <"$out")" >&2
        cat "$out" >&2
        printf '[smoke-debug] ---\n' >&2
    fi
    grep '^RESULT ' "$out" || true
    rm -f "$out"
}

# -- §0 sidecar primitives ---------------------------------------------------

section "§0 sidecar primitives"

if docker image inspect sbx-cgc-sidecar:local >/dev/null 2>&1; then
    ok "sidecar image present"
else
    nope "sidecar image sbx-cgc-sidecar:local missing — run sbx/host-mcp/build.sh"
fi

port="$("$repo/sbx/host-mcp/sidecar-up.sh" "$project" 2>/dev/null || true)"
if [[ "$port" =~ ^[0-9]{4}$ ]] && [ "$port" -ge 8000 ] && [ "$port" -lt 9000 ]; then
    ok "sidecar-up.sh printed port $port"
else
    nope "sidecar-up.sh did not return a port in 8000-8999 (got: '$port')"
fi

if docker ps --filter "label=sbx.project=$project" --format '{{.Names}}' \
        | grep -qx "cgc-sidecar-$project"; then
    ok "cgc-sidecar-$project running with label sbx.project=$project"
else
    nope "cgc-sidecar-$project not listed by docker ps"
fi

if curl -fsS "http://127.0.0.1:$port/health" >/dev/null; then
    ok "host-side /health reachable on 127.0.0.1:$port"
else
    nope "host-side /health probe failed on 127.0.0.1:$port"
fi

# Idempotency: a second sidecar-up.sh must print the same port.
port2="$("$repo/sbx/host-mcp/sidecar-up.sh" "$project" 2>/dev/null || true)"
if [ "$port2" = "$port" ]; then
    ok "sidecar-up.sh is idempotent (same port on re-run)"
else
    nope "sidecar-up.sh second run returned '$port2', expected '$port'"
fi

# Concurrency invariant: exactly one cgc child process inside the container.
cgc_children="$(docker top "cgc-sidecar-$project" 2>/dev/null \
    | awk 'NR>1 && $0 ~ /cgc mcp start/ {n++} END {print n+0}')"
if [ "$cgc_children" = 1 ]; then
    ok "exactly one 'cgc mcp start' child process"
else
    nope "expected 1 cgc child, found $cgc_children"
fi

# -- §1 host provisioning (idempotent re-run) --------------------------------

section "§1 host provisioning"

# Don't do a cold teardown/reprovision here — smoke.sh is non-destructive.
# Instead assert that provision.sh is safely idempotent against the current state.
if bash "$repo/sbx/provision.sh" "$project" >/dev/null 2>&1; then
    ok "provision.sh $project idempotent exit 0"
else
    nope "provision.sh $project exited non-zero"
fi

if sbx ls -q 2>/dev/null | grep -qx "$vm"; then
    ok "sbx ls shows $vm"
else
    nope "sbx ls does not show $vm"
fi

# -- §2/§4/§5/§6/§11 batched in-sandbox work ---------------------------------
#
# One `sbx exec` for all of them: cheaper and avoids the sbx auto-stop race
# that bites consecutive exec calls. Note: plans/06-verification.md §2 lists
# "docker absent inside VM" as a negative check, but the sbx shell-docker
# template ships docker on purpose — the plan assumption was wrong. Dropping
# that assertion here; plan will be patched separately.

section "§2/§4/§5/§6/§11/§12 in-sandbox batch"

# Wait for the sandbox to fully settle after the provision.sh internal exec,
# so the upcoming long-running batch doesn't get cut off by sbx's async stop.
note "waiting for sandbox to settle before long batch exec"
wait_for_sandbox_stopped || nope "sandbox did not reach stopped state within 30s"

# IMPORTANT: do ALL in-sandbox work in a single `sbx exec` call.
#
# `sbx` auto-stops a sandbox a few seconds after the exec command that
# started it returns. Two consecutive `sbx exec` calls race that stop: the
# second exec starts while the pending auto-stop from the first is still in
# flight, and the second exec then gets killed mid-run (~4s in) when the
# stop lands. Observed symptom: the second exec emits only its first few
# lines before being cut off. Merging everything into one call sidesteps
# the race entirely; a single long-running exec is never itself interrupted
# because no prior exec's auto-stop is pending.
#
# Plan note: plans/06-verification.md §2 listed "docker absent inside VM"
# as a negative check, but the sbx shell-docker template ships docker on
# purpose — that plan assumption is wrong. Dropping the assertion here;
# plan to be patched separately.

batch_script='set -u
rpt() { printf "RESULT %s %s\n" "$1" "$2"; }

# ---- §2 inside-VM sanity ----
if ls -ld /work /bridge /opt/workgroup >/dev/null 2>&1; then
  rpt ok "mounts /work /bridge /opt/workgroup"
else
  rpt fail "mounts /work /bridge /opt/workgroup"
fi

if [ -f /etc/workgroup/sidecar-port ] && curl -fsS "http://host.docker.internal:$(cat /etc/workgroup/sidecar-port)/health" >/dev/null 2>&1; then
  rpt ok "in-sandbox sidecar /health reachable"
else
  rpt fail "in-sandbox sidecar /health unreachable"
fi

if command -v workgroup >/dev/null && command -v bridge-send >/dev/null && command -v bridge-recv >/dev/null && command -v bridge-peek >/dev/null && command -v bridge-watch >/dev/null && command -v bridge-init >/dev/null; then
  rpt ok "workgroup + bridge-* all on PATH"
else
  rpt fail "workgroup + bridge-* on PATH"
fi

# ---- §4 bridge primitives (delegated to test-bridge.sh) ----
if /opt/workgroup/test-bridge.sh >/tmp/smoke-bridge.log 2>&1; then
  rpt ok "test-bridge.sh passed in-sandbox"
else
  rpt fail "test-bridge.sh failed (see /tmp/smoke-bridge.log in sandbox)"
fi

# ---- §5/§6/§11 manifest + happy path + teardown (delegated) ----
if /opt/workgroup/test-workgroup.sh >/tmp/smoke-workgroup.log 2>&1; then
  rpt ok "test-workgroup.sh passed in-sandbox (39 assertions)"
else
  rpt fail "test-workgroup.sh failed (see /tmp/smoke-workgroup.log in sandbox)"
fi

# ---- §12 parallel isolation ----
# Bring both up, cross-check, tear down. All inside the same shell so the
# tmux server seen by `workgroup ls` is the same one that `workgroup up`
# created (otherwise a fresh sbx exec would spawn a different tmux server
# and `ls` would miss the sessions).

# Clean any leftovers from a previous smoke run.
# `workgroup down --force` drops the session + bridge + worktree, but
# leaves the branch behind (consistent with normal user workflows — work
# may still live on the branch). For smoke-test idempotency we also nuke
# the wg/feature-a and wg/feature-b branches so a fresh `workgroup up`
# does not trip "branch already exists".
workgroup down feature-a --force >/dev/null 2>&1 || true
workgroup down feature-b --force >/dev/null 2>&1 || true
git -C /work branch -D wg/feature-a >/dev/null 2>&1 || true
git -C /work branch -D wg/feature-b >/dev/null 2>&1 || true

if workgroup up /opt/workgroup/examples/feature-a.yaml >/tmp/smoke-fa.log 2>&1; then
  rpt ok "workgroup up feature-a"
else
  rpt fail "workgroup up feature-a (see /tmp/smoke-fa.log)"
fi

if workgroup up /opt/workgroup/examples/feature-b.yaml >/tmp/smoke-fb.log 2>&1; then
  rpt ok "workgroup up feature-b"
else
  rpt fail "workgroup up feature-b (see /tmp/smoke-fb.log)"
fi

ls_out=$(workgroup ls 2>/dev/null || true)
if printf "%s" "$ls_out" | grep -q feature-a && printf "%s" "$ls_out" | grep -q feature-b; then
  rpt ok "workgroup ls lists feature-a and feature-b"
else
  rpt fail "workgroup ls missing feature-a or feature-b"
fi

if [ -f /bridge/feature-a/state.json ] && [ -f /bridge/feature-b/state.json ] && ! cmp -s /bridge/feature-a/state.json /bridge/feature-b/state.json; then
  rpt ok "feature-a and feature-b have independent state.json"
else
  rpt fail "feature-a/feature-b state.json missing or identical"
fi

if workgroup down feature-a --force >/dev/null 2>&1 && workgroup down feature-b --force >/dev/null 2>&1; then
  rpt ok "cleaned up feature-a and feature-b"
else
  rpt fail "cleanup failed"
fi
'

while IFS= read -r line; do
    case $line in
        "RESULT ok "*)   ok   "${line#RESULT ok }" ;;
        "RESULT fail "*) nope "${line#RESULT fail }" ;;
    esac
done < <(in_sbx_batch "$batch_script")

# -- done --------------------------------------------------------------------

summary
[ "$fail" = 0 ]
