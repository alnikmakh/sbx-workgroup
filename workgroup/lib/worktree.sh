#!/bin/sh
# Phase 04 worktree resolution. Three modes:
#   default  → git worktree add <WORKTREE_ROOT>/<name> -b <branch> [<base>]
#   explicit → use user-supplied path, assert it is a valid worktree
#   none     → use /work directly (with a warning about concurrent writes)
#
# $WORK_ROOT (default /work) lets tests point at a scratch repo.
# $WORKTREE_ROOT is where default-mode worktrees live — outside $WORK_ROOT so
# cgc indexing of /work doesn't see a duplicate copy of the repo. Resolution:
#   1. Env var already set (tests, explicit override).
#   2. /etc/workgroup/worktree-root, populated by postinstall.sh from the
#      host-mounted ~/sbx-worktrees/<project> directory.
#   3. Fallback to $WORK_ROOT/worktrees (legacy — keeps tests green and
#      non-sandbox runs working, at the cost of the cgc-duplication bug).

: "${WORK_ROOT:=/work}"
if [ -z "${WORKTREE_ROOT:-}" ]; then
    if [ -r /etc/workgroup/worktree-root ]; then
        WORKTREE_ROOT=$(cat /etc/workgroup/worktree-root)
    else
        WORKTREE_ROOT="$WORK_ROOT/worktrees"
    fi
fi

_wt_die() { echo "worktree: $*" >&2; return 1; }

worktree_resolve() {
  # $1 = name, $2 = mode (default|explicit|none), $3 = branch, $4 = base, $5 = path-if-explicit
  # Echoes the resolved absolute worktree path on success.
  _name=$1 _mode=$2 _branch=$3 _base=$4 _path=$5

  case $_mode in
    none)
      echo "worktree: warning: using $WORK_ROOT directly; concurrent writes possible" >&2
      printf '%s' "$WORK_ROOT"
      return 0
      ;;
    explicit)
      [ -n "$_path" ] || { _wt_die "explicit mode requires a path"; return 1; }
      [ -d "$_path" ] || { _wt_die "path does not exist: $_path"; return 1; }
      # Assert it is a git worktree (bare .git file or dir both OK).
      git -C "$_path" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || { _wt_die "not a git worktree: $_path"; return 1; }
      (CDPATH='' cd -- "$_path" && pwd)
      return 0
      ;;
    default)
      _wt="$WORKTREE_ROOT/$_name"
      if [ -d "$_wt" ]; then
        # Already present from an earlier up — reuse it, but verify branch.
        _cur=$(git -C "$_wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')
        if [ -n "$_branch" ] && [ "$_cur" != "$_branch" ]; then
          _wt_die "existing worktree $_wt is on '$_cur', expected '$_branch'"
          return 1
        fi
        printf '%s' "$_wt"
        return 0
      fi
      mkdir -p "$WORKTREE_ROOT"
      if [ -n "$_base" ]; then
        git -C "$WORK_ROOT" rev-parse --verify "$_base" >/dev/null 2>&1 \
          || { _wt_die "base ref not found in $WORK_ROOT: $_base"; return 1; }
        git -C "$WORK_ROOT" worktree add "$_wt" -b "$_branch" "$_base" >&2 \
          || { _wt_die "git worktree add failed"; return 1; }
      else
        git -C "$WORK_ROOT" worktree add "$_wt" -b "$_branch" >&2 \
          || { _wt_die "git worktree add failed"; return 1; }
      fi
      printf '%s' "$_wt"
      return 0
      ;;
    *)
      _wt_die "unknown mode: $_mode"
      return 1
      ;;
  esac
}

worktree_remove_if_clean() {
  # $1 = path. Returns 0 if removed, 1 if dirty, 2 if not a worktree.
  _p=$1
  git -C "$_p" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 2
  _dirty=$(git -C "$_p" status --porcelain)
  [ -z "$_dirty" ] || return 1
  git -C "$WORK_ROOT" worktree remove "$_p" >&2
}
