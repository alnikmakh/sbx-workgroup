#!/bin/sh
# Phase 04 tmux wrapper. One session per workgroup. Two windows: "agents" (one
# pane per agent, laid out per manifest) and "watch" (bridge-watch).

_tx_die() { echo "tmux: $*" >&2; return 1; }

tmux_session_exists() {
  tmux has-session -t "=$1" 2>/dev/null
}

tmux_create_session() {
  # $1 = session name, $2 = layout, $3 = bridge dir, $4.. = agent ids (in order)
  # Persists an agent->pane_id map at $bridge_dir/.panes. Pane ids are stable
  # for the session lifetime, unlike pane titles (which interactive shells
  # overwrite via PROMPT escape sequences) and pane indices (which renumber
  # on splits).
  _name=$1; shift
  _layout=$1; shift
  _bd=$1; shift
  [ $# -ge 1 ] || { _tx_die "no agents"; return 1; }
  _pmap=$_bd/.panes
  : > "$_pmap"

  _first=$1; shift
  tmux new-session -d -s "$_name" -n agents \
    || { _tx_die "new-session failed"; return 1; }
  _pid=$(tmux display-message -p -t "$_name:agents.0" '#{pane_id}') \
    || { _tx_die "display-message failed"; return 1; }
  _tx_label_pane "$_pid" "$_first"
  printf '%s\t%s\n' "$_first" "$_pid" >> "$_pmap"

  for _a in "$@"; do
    _pid=$(tmux split-window -t "$_name:agents" -h -P -F '#{pane_id}') \
      || { _tx_die "split-window failed"; return 1; }
    _tx_label_pane "$_pid" "$_a"
    printf '%s\t%s\n' "$_a" "$_pid" >> "$_pmap"
    tmux select-layout -t "$_name:agents" "$_layout" >/dev/null 2>&1 || true
  done
  tmux select-layout -t "$_name:agents" "$_layout" >/dev/null 2>&1 || true

  # Show the agent label on the pane border. We read @wg_agent (set per-pane
  # below) instead of #{pane_title} because claude and most shells overwrite
  # pane_title via OSC escape sequences, which would erase our labels.
  tmux set-option -t "$_name" pane-border-status top >/dev/null 2>&1 || true
  tmux set-option -t "$_name" pane-border-format \
    ' #{?#{@wg_agent},#{@wg_agent},#{pane_title}} ' >/dev/null 2>&1 || true
}

_tx_label_pane() {
  # $1 = pane id, $2 = agent name. Sets both pane_title (for tests / fallback)
  # and a pane user option that won't be clobbered by terminal escapes.
  tmux select-pane -t "$1" -T "$2"
  tmux set-option -p -t "$1" @wg_agent "$2" >/dev/null 2>&1 || true
}

tmux_add_watch_window() {
  # $1 = session name, $2 = workgroup name (for bridge-watch arg)
  tmux new-window -t "$1:" -n watch "bridge-watch $2" \
    || { _tx_die "new-window watch failed"; return 1; }
}

tmux_pane_id_for_agent() {
  # $1 = bridge dir, $2 = agent id. Echoes tmux pane id (e.g. %5).
  awk -v want="$2" '$1==want {print $2; exit}' "$1/.panes" 2>/dev/null
}

tmux_send_launch() {
  # $1 = session, $2 = agent id, $3 = cwd, $4 = bridge dir, $5 = peers_out,
  # $6 = peers_in, $7 = role file path
  _sess=$1 _ag=$2 _cwd=$3 _bd=$4 _out=$5 _in=$6 _role=$7
  _pid=$(tmux_pane_id_for_agent "$_bd" "$_ag")
  [ -n "$_pid" ] || { _tx_die "no pane for agent $_ag"; return 1; }
  # unset ANTHROPIC_API_KEY: sbx bakes ANTHROPIC_API_KEY=proxy-managed into
  # pid 1, which claude mistakes for a real key and rejects, masking the
  # OAuth creds set up by `claude /login`. Drop it for this pane only.
  _cmd="cd $(_tx_q "$_cwd") && unset ANTHROPIC_API_KEY && BRIDGE_DIR=$(_tx_q "$_bd") AGENT_ID=$(_tx_q "$_ag") AGENT_PEERS_OUT=$(_tx_q "$_out") AGENT_PEERS_IN=$(_tx_q "$_in") claude --dangerously-skip-permissions --append-system-prompt \"\$(cat $(_tx_q "$_role"))\""
  tmux send-keys -t "$_pid" "$_cmd" C-m
}

_tx_q() {
  # shell-quote $1 into single quotes
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

tmux_kill_session() {
  tmux kill-session -t "=$1" 2>/dev/null || true
}
