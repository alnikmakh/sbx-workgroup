#!/bin/sh
# Phase 04 tmux wrapper. One session per workgroup. Two windows: "agents" (one
# pane per agent, laid out per manifest) and "watch" (bridge-watch).

_tx_die() { echo "tmux: $*" >&2; return 1; }

tmux_session_exists() {
  tmux has-session -t "=$1" 2>/dev/null
}

tmux_create_session() {
  # $1 = session name, $2 = layout, $3.. = agent ids (in order)
  _name=$1; shift
  _layout=$1; shift
  [ $# -ge 1 ] || { _tx_die "no agents"; return 1; }

  _first=$1; shift
  tmux new-session -d -s "$_name" -n agents \
    || { _tx_die "new-session failed"; return 1; }
  tmux select-pane -t "$_name:agents.0" -T "$_first"

  for _a in "$@"; do
    tmux split-window -t "$_name:agents" -h \
      || { _tx_die "split-window failed"; return 1; }
    tmux select-pane -T "$_a"
    tmux select-layout -t "$_name:agents" "$_layout" >/dev/null 2>&1 || true
  done
  tmux select-layout -t "$_name:agents" "$_layout" >/dev/null 2>&1 || true
}

tmux_add_watch_window() {
  # $1 = session name, $2 = workgroup name (for bridge-watch arg)
  tmux new-window -t "$1:" -n watch "bridge-watch $2" \
    || { _tx_die "new-window watch failed"; return 1; }
}

tmux_pane_index_for_agent() {
  # $1 = session, $2 = agent id. Echoes pane index (0-based).
  tmux list-panes -t "$1:agents" -F '#{pane_index} #{pane_title}' \
    | awk -v want="$2" '$2==want {print $1; exit}'
}

tmux_send_launch() {
  # $1 = session, $2 = agent id, $3 = cwd, $4 = bridge dir, $5 = peers_out,
  # $6 = peers_in, $7 = role file path
  _sess=$1 _ag=$2 _cwd=$3 _bd=$4 _out=$5 _in=$6 _role=$7
  _idx=$(tmux_pane_index_for_agent "$_sess" "$_ag")
  [ -n "$_idx" ] || { _tx_die "no pane for agent $_ag"; return 1; }
  # Use single-quoted heredoc-style: shell in the pane expands $(cat …).
  # unset ANTHROPIC_API_KEY: sbx bakes ANTHROPIC_API_KEY=proxy-managed into
  # pid 1, which claude mistakes for a real key and rejects, masking the
  # OAuth creds set up by `claude /login`. Drop it for this pane only.
  _cmd="cd $(_tx_q "$_cwd") && unset ANTHROPIC_API_KEY && BRIDGE_DIR=$(_tx_q "$_bd") AGENT_ID=$(_tx_q "$_ag") AGENT_PEERS_OUT=$(_tx_q "$_out") AGENT_PEERS_IN=$(_tx_q "$_in") claude --dangerously-skip-permissions --append-system-prompt \"\$(cat $(_tx_q "$_role"))\""
  tmux send-keys -t "$_sess:agents.$_idx" "$_cmd" C-m
}

_tx_q() {
  # shell-quote $1 into single quotes
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

tmux_kill_session() {
  tmux kill-session -t "=$1" 2>/dev/null || true
}
