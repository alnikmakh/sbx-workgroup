#!/bin/sh
# Phase 03 bridge primitives. POSIX sh + jq + locked_subshell. No fsync;
# same-FS rename gives atomic visibility, which is all v1 needs (see
# plans/03-bridge-protocol.md).
#
# Library functions are positional; the bin/ wrappers parse flags and call in.
# $BRIDGE_ROOT must be set by the caller (bin/workgroup sources lib/config.sh
# which exports it). Tests set it explicitly to a scratch dir. We fall back to
# $HOME/.local/share/workgroup/bridges only as a last resort so direct callers
# of this library don't crash on an unset var.

: "${BRIDGE_ROOT:=${XDG_DATA_HOME:-$HOME/.local/share}/workgroup/bridges}"

# locked_subshell <lockfile> <fn>: run <fn> in a subshell holding an exclusive
# lock on <lockfile>. Linux uses flock(1); macOS (no flock) falls back to an
# atomic mkdir-of-sibling-dir with EXIT-trap cleanup. Inlined here rather than
# split into its own file so test scripts that source bridge.sh directly don't
# need a separate include path. Used by both bridge.sh and bin/workgroup.
if command -v flock >/dev/null 2>&1; then
  locked_subshell() {
    _lk=$1; _fn=$2
    (
      flock 9
      "$_fn"
    ) 9>"$_lk"
  }
else
  locked_subshell() {
    _lk=$1; _fn=$2
    (
      _ld="${_lk}.d"
      _tries=0
      while ! mkdir "$_ld" 2>/dev/null; do
        _tries=$((_tries + 1))
        if [ "$_tries" -gt 600 ]; then
          echo "lock: timed out waiting for $_ld (30s)" >&2
          exit 1
        fi
        sleep 0.05 2>/dev/null || sleep 1
      done
      trap 'rmdir "$_ld" 2>/dev/null || true' EXIT INT TERM
      "$_fn"
    )
  }
fi

bridge_path() {
  # $1 = workgroup name (or absolute path); resolve to a bridge dir.
  case $1 in
    /*) printf '%s' "$1" ;;
    *)  printf '%s/%s' "$BRIDGE_ROOT" "$1" ;;
  esac
}

bridge_init() {
  # $1 = bridge dir (or name), $2 = comma-sep agents, $3 = edge list "a->b,b->c"
  _bd=$(bridge_path "$1"); _agents=$2; _edges=$3
  if [ -f "$_bd/state.json" ]; then
    _have=$(jq -r '.agents | map(.id) | sort | join(",")' "$_bd/state.json")
    _want=$(printf '%s' "$_agents" | tr ',' '\n' | sort | paste -sd ',' -)
    if [ "$_have" != "$_want" ]; then
      echo "bridge_init: $_bd exists with agents [$_have], refuses [$_want]" >&2
      return 1
    fi
    return 0
  fi
  mkdir -p "$_bd/.counters" "$_bd/plans" "$_bd/reports" "$_bd/notes" \
           "$_bd/archive" "$_bd/roles"
  IFS=','; for a in $_agents; do
    mkdir -p "$_bd/inbox/$a" "$_bd/outbox/$a"
    : > "$_bd/.counters/$a"
  done
  unset IFS
  _agents_json=$(printf '%s' "$_agents" | jq -R 'split(",") | map({id:., role:.})')
  _edges_json=$(printf '%s' "$_edges" | jq -R '
    split(",") | map(split("->") | {from:.[0], to:.[1]})')
  jq -n --arg name "$(basename "$_bd")" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson agents "$_agents_json" \
        --argjson edges "$_edges_json" \
    '{name:$name, created_at:$ts, agents:$agents, edges:$edges}' \
    > "$_bd/state.json"
  : > "$_bd/state.json.lock"
}

bridge_load() {
  # $1 = bridge dir (or name). Exports BRIDGE_STATE_AGENTS, BRIDGE_STATE_EDGES.
  _bd=$(bridge_path "$1")
  BRIDGE_STATE_AGENTS=$(jq -r '.agents | map(.id) | join(",")' "$_bd/state.json")
  BRIDGE_STATE_EDGES=$(jq -r '.edges | map("\(.from)->\(.to)") | join(",")' "$_bd/state.json")
  export BRIDGE_STATE_AGENTS BRIDGE_STATE_EDGES
}

bridge_topology_allows() {
  # $1 = bridge dir (or name), $2 = from, $3 = to
  _bd=$(bridge_path "$1")
  jq -e --arg f "$2" --arg t "$3" \
    '.edges | any(.from == $f and .to == $t)' \
    "$_bd/state.json" >/dev/null
}

_bridge_next_id_body() {
  _cur=$(cat "$_bd/.counters/$_ag" 2>/dev/null)
  _cur=${_cur:-0}
  _next=$((_cur + 1))
  printf '%s' "$_next" > "$_bd/.counters/$_ag"
  printf '%s-%s-%03d' "$(date -u +%Y-%m-%dT%H-%M-%SZ)" "$_ag" "$_next"
}
bridge_next_signal_id() {
  # $1 = bridge dir (or name), $2 = agent
  _bd=$(bridge_path "$1"); _ag=$2
  locked_subshell "$_bd/state.json.lock" _bridge_next_id_body
}

bridge_atomic_write() {
  # $1 = dest path; stdin = content. Same-FS rename is atomic; no fsync.
  _dest=$1
  _dir=$(dirname "$_dest")
  _base=$(basename "$_dest")
  _tmp="$_dir/.${_base}.tmp.$$"
  cat > "$_tmp"
  mv "$_tmp" "$_dest"
}

bridge_archive_signal() {
  # $1 = bridge dir (or name), $2 = agent, $3 = signal id.
  # Moves the signal JSON only; the payload file stays in plans/reports/notes.
  _bd=$(bridge_path "$1"); _ag=$2; _id=$3
  _src="$_bd/inbox/$_ag/$_id.json"
  [ -f "$_src" ] || { echo "no such signal: $_id for $_ag" >&2; return 1; }
  mv "$_src" "$_bd/archive/$_id.json"
}
