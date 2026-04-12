#!/bin/sh
# Phase 03 contract tests. Run: ./test.sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH="$HERE/bin:$PATH"
. "$HERE/lib/bridge.sh"

BD=$(mktemp -d)
trap 'rm -rf "$BD"' EXIT
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
nope() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

echo "[1] bridge_init lays out directory tree + state.json"
bridge_init "$BD/wg" "planner,reviewer,executor" \
  "planner->reviewer,reviewer->planner,reviewer->executor,executor->reviewer"
for d in inbox/planner inbox/reviewer inbox/executor \
         outbox/planner outbox/reviewer outbox/executor \
         plans reports notes archive roles .counters; do
  [ -d "$BD/wg/$d" ] || { nope "missing dir $d"; continue; }
done
[ -f "$BD/wg/state.json" ] && ok "state.json exists" || nope "state.json missing"
jq -e '.agents | length == 3' "$BD/wg/state.json" >/dev/null \
  && ok "state.json has 3 agents" || nope "agent count wrong"

echo "[2] topology enforcement"
bridge_topology_allows "$BD/wg" planner reviewer \
  && ok "planner->reviewer allowed" || nope "planner->reviewer rejected"
bridge_topology_allows "$BD/wg" planner executor \
  && nope "planner->executor should be rejected" \
  || ok "planner->executor rejected"

echo "[3] bridge-send happy path"
echo "hi from planner" > "$BD/msg.md"
export BRIDGE_DIR="$BD/wg" AGENT_ID=planner
ID=$("$HERE/bin/bridge-send" --to reviewer --kind plan --file "$BD/msg.md" \
        --subject "first plan")
[ -n "$ID" ] && ok "send returned id: $ID" || nope "send returned empty id"
[ -f "$BD/wg/inbox/reviewer/$ID.json" ] && ok "signal in recipient inbox" \
  || nope "signal missing from inbox"
[ -f "$BD/wg/outbox/planner/$ID.json" ] && ok "audit copy in outbox" \
  || nope "outbox copy missing"
[ -f "$BD/wg/plans/$ID.md" ] && ok "payload in plans/" || nope "payload missing"
jq -e --arg id "$ID" '.id == $id and .from == "planner" and .to == "reviewer"' \
  "$BD/wg/inbox/reviewer/$ID.json" >/dev/null \
  && ok "signal JSON fields match schema" || nope "signal JSON mismatch"

echo "[4] bridge-send rejects undeclared edges"
if AGENT_ID=planner "$HERE/bin/bridge-send" --to executor --kind note \
     --file "$BD/msg.md" 2>/dev/null; then
  nope "undeclared edge was accepted"
else
  ok "undeclared edge rejected (exit nonzero)"
fi

echo "[5] parallel sends produce distinct ids, no partial files"
N=20
i=0
while [ $i -lt $N ]; do
  AGENT_ID=reviewer "$HERE/bin/bridge-send" --to planner --kind note \
    --file "$BD/msg.md" --subject "burst $i" >"$BD/ids.$i" 2>&1 &
  i=$((i+1))
done
wait
got=$(cat "$BD"/ids.* | sort -u | wc -l)
[ "$got" = "$N" ] && ok "$N distinct ids from parallel sends" \
  || nope "expected $N ids, got $got"
# No .tmp leftovers in inbox (would mean atomic rename failed)
tmp_count=$(find "$BD/wg/inbox" -name '.*.tmp*' | wc -l)
[ "$tmp_count" = 0 ] && ok "no partial .tmp files in inbox" \
  || nope "$tmp_count partial tmp files leaked"
# Every inbox signal is valid JSON (proves no partial writes were observed)
all_valid=1
for f in "$BD/wg/inbox/planner"/*.json; do
  jq -e . "$f" >/dev/null 2>&1 || { all_valid=0; break; }
done
[ "$all_valid" = 1 ] && ok "all $N received signals are valid JSON" \
  || nope "at least one received signal was not valid JSON"

echo
echo "passed: $pass    failed: $fail"
[ "$fail" = 0 ]
