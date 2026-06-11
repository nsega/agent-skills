#!/usr/bin/env bash
#
# link.sh — manage per-folder symlinks from a source skills dir into a target
# skills directory (Claude Code or Codex).
#
# Usage: link.sh <install|uninstall|status> <target_dir> <src_dir> [skill...]
#
#   src_dir   directory holding <name>/SKILL.md skill folders to link from.
#   skill...  optional whitelist of skill names. If omitted, every skill in
#             src_dir is considered. Applies to install/status only;
#             uninstall always acts on all links pointing into src_dir.
#
# Contract:
#   install   — symlink each selected skill into target_dir.
#               * already-correct link    -> "ok"     (no write; idempotent)
#               * stale link into src_dir  -> "fixed"  (repointed)
#               * foreign symlink          -> "warn"   (skipped, never clobbered)
#               * existing non-symlink     -> "warn"   (skipped, never clobbered)
#               * missing                  -> "linked" (created)
#   uninstall — remove ONLY symlinks in target_dir that point into src_dir.
#   status    — read-only report: ok / missing / wrong / blocked(non-symlink).
#
# A non-existent src_dir is a no-op (warn + exit 0), so a Makefile can list
# optional source repos that may not be present on every machine.
#
set -euo pipefail

cmd="${1:-}"
target_dir="${2:-}"
src_dir="${3:-}"
shift 3 2>/dev/null || true
names=("$@")

if [ -z "$cmd" ] || [ -z "$target_dir" ] || [ -z "$src_dir" ]; then
  echo "usage: link.sh <install|uninstall|status> <target_dir> <src_dir> [skill...]" >&2
  exit 2
fi

# A missing source repo is fine — just skip it.
if [ ! -d "$src_dir" ]; then
  echo "warn    source dir not found: $src_dir (skipping)" >&2
  exit 0
fi
src_dir="$(cd "$src_dir" && pwd)"

# True if $1 (a symlink target) points somewhere inside src_dir.
points_into_src() {
  case "$1" in
    "$src_dir"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Emit the skill names to act on: the explicit whitelist (validated against
# src_dir), or every dir in src_dir that has a SKILL.md.
selected_skills() {
  local d n
  if [ "${#names[@]}" -gt 0 ]; then
    for n in "${names[@]}"; do
      if [ -f "$src_dir/$n/SKILL.md" ]; then
        echo "$n"
      else
        echo "warn    $n -> no SKILL.md in $src_dir, skipping" >&2
      fi
    done
  else
    for d in "$src_dir"/*/; do
      [ -d "$d" ] || continue
      [ -f "${d}SKILL.md" ] || continue
      basename "$d"
    done
  fi
}

do_install() {
  mkdir -p "$target_dir"
  local name link want cur
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    link="$target_dir/$name"
    want="$src_dir/$name"
    if [ -L "$link" ]; then
      cur="$(readlink "$link")"
      if [ "$cur" = "$want" ]; then
        echo "ok      $name"
      elif points_into_src "$cur"; then
        ln -sfn "$want" "$link"
        echo "fixed   $name"
      else
        echo "warn    $name -> foreign symlink ($cur), skipping"
      fi
    elif [ -e "$link" ]; then
      echo "warn    $name -> existing non-symlink, skipping"
    else
      ln -s "$want" "$link"
      echo "linked  $name"
    fi
  done < <(selected_skills)
}

do_uninstall() {
  [ -d "$target_dir" ] || { echo "nothing to do: $target_dir does not exist"; return 0; }
  local entry cur
  for entry in "$target_dir"/*; do
    [ -L "$entry" ] || continue
    cur="$(readlink "$entry")"
    if points_into_src "$cur"; then
      rm "$entry"
      echo "unlinked $(basename "$entry")"
    fi
  done
}

do_status() {
  local name link want cur
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    link="$target_dir/$name"
    want="$src_dir/$name"
    if [ -L "$link" ]; then
      cur="$(readlink "$link")"
      if [ "$cur" = "$want" ]; then
        echo "ok      $name"
      else
        echo "wrong   $name -> $cur"
      fi
    elif [ -e "$link" ]; then
      echo "blocked $name (non-symlink in target)"
    else
      echo "missing $name"
    fi
  done < <(selected_skills)
}

case "$cmd" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
  status)    do_status ;;
  *) echo "unknown command: $cmd" >&2; exit 2 ;;
esac
