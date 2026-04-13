#!/bin/sh
# Phase 04 manifest parser + validator. POSIX sh + go-yq v4 (mikefarah).
#
# After a successful manifest_parse+manifest_validate, these vars are set:
#   WG_NAME          workgroup name
#   WG_BRANCH        worktree branch (default wg/<name>)
#   WG_BASE          worktree base ref ("" if unset)
#   WG_LAYOUT        tmux layout
#   WG_AGENTS        csv of agent ids, preserves manifest order
#   WG_EDGES         csv of "a->b" pairs
# And per-agent (id uppercased, non-alnum → _):
#   WG_ROLE_<id>         role name (may be empty if role_file used)
#   WG_ROLE_FILE_<id>    path (may be empty if role used)

: "${WG_LAYOUTS:=tiled even-horizontal even-vertical main-vertical}"

_wg_sanitize() {
  # uppercase + non-alnum → _  (for shell var names)
  printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_' | tr -cd 'A-Z0-9_'
}

_wg_die() { echo "manifest: $*" >&2; return 1; }

manifest_parse() {
  # $1 = manifest file. Sets WG_* globals. Does NOT validate semantics.
  _f=$1
  [ -f "$_f" ] || { _wg_die "no such file: $_f"; return 1; }

  WG_NAME=$(yq -r '.name // ""' "$_f") || return 1
  WG_BRANCH=$(yq -r '.worktree.branch // ""' "$_f")
  WG_BASE=$(yq -r '.worktree.base // ""' "$_f")
  WG_LAYOUT=$(yq -r '.layout // "tiled"' "$_f")

  _ids=$(yq -r '.agents[].id // ""' "$_f") || return 1
  WG_AGENTS=$(printf '%s' "$_ids" | awk 'NF{printf "%s%s", (NR>1?",":""), $0}')

  _n=$(yq -r '.agents | length' "$_f")
  _i=0
  while [ "$_i" -lt "$_n" ]; do
    _id=$(yq -r ".agents[$_i].id // \"\"" "$_f")
    _role=$(yq -r ".agents[$_i].role // \"\"" "$_f")
    _rfile=$(yq -r ".agents[$_i].role_file // \"\"" "$_f")
    _k=$(_wg_sanitize "$_id")
    eval "WG_ROLE_${_k}=\$_role"
    eval "WG_ROLE_FILE_${_k}=\$_rfile"
    _i=$((_i + 1))
  done

  # edges: yaml list of "a -> b" strings. Normalize whitespace; join csv.
  _edges=$(yq -r '.edges[] // ""' "$_f" \
           | sed -e 's/[[:space:]]*->[[:space:]]*/->/g' -e 's/[[:space:]]//g')
  WG_EDGES=$(printf '%s' "$_edges" | awk 'NF{printf "%s%s", (NR>1?",":""), $0}')

  [ -z "$WG_BRANCH" ] && WG_BRANCH="wg/$WG_NAME"
  export WG_NAME WG_BRANCH WG_BASE WG_LAYOUT WG_AGENTS WG_EDGES
}

manifest_validate() {
  # $1 = manifest file (for resolving role_file relative paths and role templates)
  # $2 = templates root (default: <script-dir>/../templates)
  _f=$1
  _troot=${2:-}
  if [ -z "$_troot" ]; then
    _here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
    _troot="$_here/../templates"
  fi

  case $WG_NAME in
    '') _wg_die "name is required"; return 1 ;;
  esac
  printf '%s' "$WG_NAME" | grep -Eq '^[a-z0-9][a-z0-9-]{0,30}$' \
    || { _wg_die "name '$WG_NAME' must match [a-z0-9][a-z0-9-]{0,30}"; return 1; }

  [ -n "$WG_AGENTS" ] || { _wg_die "agents: must be non-empty"; return 1; }

  # dup detection
  _dup=$(printf '%s' "$WG_AGENTS" | tr ',' '\n' | sort | uniq -d | head -1)
  [ -z "$_dup" ] || { _wg_die "duplicate agent id: $_dup"; return 1; }

  # per-agent role resolution
  _manifest_dir=$(CDPATH='' cd -- "$(dirname -- "$_f")" && pwd)
  _saved_ifs=${IFS- }
  IFS=','
  for _id in $WG_AGENTS; do
    _k=$(_wg_sanitize "$_id")
    eval "_role=\$WG_ROLE_${_k}"
    eval "_rfile=\$WG_ROLE_FILE_${_k}"
    if [ -n "$_rfile" ]; then
      case $_rfile in
        /*) _abs=$_rfile ;;
        *)  _abs="$_manifest_dir/$_rfile" ;;
      esac
      [ -s "$_abs" ] || { IFS=$_saved_ifs; _wg_die "agent '$_id': role_file not found or empty: $_rfile"; return 1; }
      eval "WG_ROLE_FILE_ABS_${_k}=\$_abs"
    elif [ -n "$_role" ]; then
      _tpl="$_troot/roles/$_role.md"
      [ -s "$_tpl" ] || { IFS=$_saved_ifs; _wg_die "agent '$_id': role template not found: $_tpl"; return 1; }
      eval "WG_ROLE_FILE_ABS_${_k}=\$_tpl"
    else
      IFS=$_saved_ifs
      _wg_die "agent '$_id': one of role or role_file is required"
      return 1
    fi
  done
  IFS=$_saved_ifs

  # edges reference declared agents
  if [ -n "$WG_EDGES" ]; then
    _saved_ifs=${IFS- }
    IFS=','
    for _e in $WG_EDGES; do
      case $_e in
        *'->'*) ;;
        *) IFS=$_saved_ifs; _wg_die "edge '$_e' must be 'a->b'"; return 1 ;;
      esac
      _from=${_e%->*}
      _to=${_e#*->}
      [ -n "$_from" ] && [ -n "$_to" ] \
        || { IFS=$_saved_ifs; _wg_die "edge '$_e' has empty endpoint"; return 1; }
      _wg_has_agent "$_from" \
        || { IFS=$_saved_ifs; _wg_die "edge '$_e': unknown agent '$_from'"; return 1; }
      _wg_has_agent "$_to" \
        || { IFS=$_saved_ifs; _wg_die "edge '$_e': unknown agent '$_to'"; return 1; }
    done
    IFS=$_saved_ifs
  fi

  # layout
  _ok=0
  for _l in $WG_LAYOUTS; do
    [ "$_l" = "$WG_LAYOUT" ] && { _ok=1; break; }
  done
  [ "$_ok" = 1 ] || { _wg_die "layout '$WG_LAYOUT' not in: $WG_LAYOUTS"; return 1; }
}

_wg_has_agent() {
  _needle=$1
  _old_ifs=${IFS- }
  IFS=','
  for _a in $WG_AGENTS; do
    if [ "$_a" = "$_needle" ]; then IFS=$_old_ifs; return 0; fi
  done
  IFS=$_old_ifs
  return 1
}

manifest_peers_out() {
  # $1 = agent id. Echoes csv of ids this agent may send to.
  _me=$1 _out=''
  [ -z "$WG_EDGES" ] && return 0
  _old_ifs=${IFS- }; IFS=','
  for _e in $WG_EDGES; do
    _from=${_e%->*}; _to=${_e#*->}
    if [ "$_from" = "$_me" ]; then
      _out=${_out:+$_out,}$_to
    fi
  done
  IFS=$_old_ifs
  printf '%s' "$_out"
}

manifest_peers_in() {
  _me=$1 _in=''
  [ -z "$WG_EDGES" ] && return 0
  _old_ifs=${IFS- }; IFS=','
  for _e in $WG_EDGES; do
    _from=${_e%->*}; _to=${_e#*->}
    if [ "$_to" = "$_me" ]; then
      _in=${_in:+$_in,}$_from
    fi
  done
  IFS=$_old_ifs
  printf '%s' "$_in"
}

manifest_role_file_for() {
  # $1 = agent id. Echoes absolute role source path.
  _k=$(_wg_sanitize "$1")
  eval "printf '%s' \"\$WG_ROLE_FILE_ABS_${_k}\""
}
