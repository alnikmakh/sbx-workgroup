#!/bin/sh
# Standalone-mode config loader.
#
# Resolves runtime paths in the order: env var → config.yaml → XDG default.
# Sourced once at the top of bin/workgroup. Safe to source multiple times.
#
# Reads ${WORKGROUP_CONFIG:-$XDG_CONFIG_HOME/workgroup/config.yaml} if it
# exists. yq is optional — if absent, only env vars and XDG defaults apply.
#
# Exports (with these defaults):
#   WORKGROUP_HOME   = $XDG_DATA_HOME/workgroup
#   BRIDGE_ROOT      = $WORKGROUP_HOME/bridges
#   WORKTREE_ROOT    = $WORKGROUP_HOME/worktrees
#   WORKGROUP_PROJECTS_ROOT = (from config only; unset if neither config nor env)
#
# WORK_ROOT is intentionally NOT defaulted here — it's per-workgroup and gets
# resolved inside cmd_up from the manifest, --source flag, or cwd.

config_load() {
  : "${XDG_CONFIG_HOME:=$HOME/.config}"
  : "${XDG_DATA_HOME:=$HOME/.local/share}"
  : "${WORKGROUP_CONFIG:=$XDG_CONFIG_HOME/workgroup/config.yaml}"

  _cfg_bridge=''
  _cfg_worktrees=''
  _cfg_home=''
  _cfg_projects=''
  WORKGROUP_MCP_BLOCK=''

  if [ -f "$WORKGROUP_CONFIG" ] && command -v yq >/dev/null 2>&1; then
    _cfg_home=$(yq -r '.workgroup_home // ""' "$WORKGROUP_CONFIG" 2>/dev/null || echo '')
    _cfg_bridge=$(yq -r '.bridge_root // ""' "$WORKGROUP_CONFIG" 2>/dev/null || echo '')
    _cfg_worktrees=$(yq -r '.worktree_root // ""' "$WORKGROUP_CONFIG" 2>/dev/null || echo '')
    _cfg_projects=$(yq -r '.projects_root // ""' "$WORKGROUP_CONFIG" 2>/dev/null || echo '')
    # MCP entries: pass through as a yq-rendered tab-separated stream
    # `name<TAB>transport<TAB>url` consumed by cmd_up.
    WORKGROUP_MCP_BLOCK=$(yq -r '
      .mcp[]? | [.name // "", .transport // "http", .url // ""] | @tsv
    ' "$WORKGROUP_CONFIG" 2>/dev/null || echo '')
  fi

  # Tilde expand the few values we read from YAML.
  _cfg_home=$(_cfg_expand "$_cfg_home")
  _cfg_bridge=$(_cfg_expand "$_cfg_bridge")
  _cfg_worktrees=$(_cfg_expand "$_cfg_worktrees")
  _cfg_projects=$(_cfg_expand "$_cfg_projects")

  : "${WORKGROUP_HOME:=${_cfg_home:-$XDG_DATA_HOME/workgroup}}"
  : "${BRIDGE_ROOT:=${_cfg_bridge:-$WORKGROUP_HOME/bridges}}"
  : "${WORKTREE_ROOT:=${_cfg_worktrees:-$WORKGROUP_HOME/worktrees}}"
  if [ -z "${WORKGROUP_PROJECTS_ROOT:-}" ] && [ -n "$_cfg_projects" ]; then
    WORKGROUP_PROJECTS_ROOT=$_cfg_projects
  fi

  export WORKGROUP_HOME BRIDGE_ROOT WORKTREE_ROOT WORKGROUP_CONFIG
  [ -n "${WORKGROUP_PROJECTS_ROOT:-}" ] && export WORKGROUP_PROJECTS_ROOT
  export WORKGROUP_MCP_BLOCK
}

_cfg_expand() {
  case $1 in
    '~') printf '%s' "$HOME" ;;
    '~/'*) printf '%s/%s' "$HOME" "${1#~/}" ;;
    *) printf '%s' "$1" ;;
  esac
}
