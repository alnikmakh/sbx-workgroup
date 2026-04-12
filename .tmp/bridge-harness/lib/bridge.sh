#!/bin/sh
# Reference implementation of bridge primitives for Phase 03.
# Shell-only (POSIX sh + jq + flock). No fsync; same-FS rename is enough.

bridge_init() {
  # $1 = bridge dir, $2 = comma-sep agents, $3 = edge list "a->b,b->c"
  _bd=$1 _agents=$2 _edges=$3
  mkdir -p "$_bd/.counters" "$_bd/plans" "$_bd/reports" "$_bd/notes" \
           "$_bd/archive" "$_bd/roles"
  # Create per-agent inbox/outbox
  IFS=','; for a in $_agents; do
    mkdir -p "$_bd/inbox/$a" "$_bd/outbox/$a"
    : > "$_bd/.counters/$a"
  done
  unset IFS
  # Compose state.json
  _agents_json=$(printf '%s\n' "$_agents" | jq -R 'split(",") | map({id:., role:.})')
  _edges_json=$(printf '%s\n' "$_edges" | jq -R '
    split(",") | map(split("->") | {from:.[0], to:.[1]})')
  jq -n --arg name "$(basename "$_bd")" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson agents "$_agents_json" \
        --argjson edges "$_edges_json" \
    '{name:$name, created_at:$ts, agents:$agents, edges:$edges}' \
    > "$_bd/state.json"
  : > "$_bd/state.json.lock"
}

bridge_topology_allows() {
  # $1 = bridge dir, $2 = from, $3 = to
  jq -e --arg f "$2" --arg t "$3" \
    '.edges | any(.from == $f and .to == $t)' \
    "$1/state.json" >/dev/null
}

bridge_next_signal_id() {
  # $1 = bridge dir, $2 = agent
  _bd=$1 _ag=$2
  _lockf="$_bd/state.json.lock"
  (
    flock 9
    _cur=$(cat "$_bd/.counters/$_ag" 2>/dev/null)
    _cur=${_cur:-0}
    _next=$((_cur + 1))
    printf '%s' "$_next" > "$_bd/.counters/$_ag"
    printf '%s-%s-%03d' "$(date -u +%Y-%m-%dT%H-%M-%SZ)" "$_ag" "$_next"
  ) 9>"$_lockf"
}

bridge_atomic_write() {
  # $1 = dest path; stdin = content
  _dest=$1
  _dir=$(dirname "$_dest")
  _base=$(basename "$_dest")
  _tmp="$_dir/.${_base}.tmp.$$"
  cat > "$_tmp"
  mv "$_tmp" "$_dest"
}
