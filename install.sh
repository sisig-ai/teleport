#!/usr/bin/env bash
# install.sh — install the teleport skill for one or more harnesses.
# usage: install.sh [--project DIR] [harness ...]
# harness names: claude cursor codex opencode
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_SRC="$SCRIPT_DIR/skill"

usage() {
  echo "usage: install.sh [--project DIR] [harness ...]" >&2
  echo "harness names: claude cursor codex opencode" >&2
  exit 1
}

PROJECT_DIR=""
FILTERS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      [[ $# -ge 2 ]] || usage
      PROJECT_DIR="$2"; shift 2 ;;
    -h|--help)
      usage ;;
    claude|cursor|codex|opencode)
      FILTERS+=("$1"); shift ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage ;;
  esac
done

if [[ ! -f "$SKILL_SRC/SKILL.md" ]]; then
  echo "error: $SKILL_SRC/SKILL.md not found. run this from the teleport repo." >&2
  exit 1
fi

declare -A USER_DESTS=(
  [claude]="$HOME/.claude/skills/teleport"
  [cursor]="$HOME/.cursor/skills/teleport"
  [codex]="$HOME/.codex/skills/teleport"
  [opencode]="$HOME/.config/opencode/skills/teleport"
)

if [[ -n "$PROJECT_DIR" ]]; then
  if [[ ${#FILTERS[@]} -gt 0 ]]; then
    for f in "${FILTERS[@]}"; do
      if [[ "$f" == "codex" || "$f" == "opencode" ]]; then
        echo "error: --project has no verified layout for '$f'. install user-level instead, or drop --project." >&2
        exit 1
      fi
    done
  fi
  declare -A DESTS=(
    [claude]="$PROJECT_DIR/.claude/skills/teleport"
    [cursor]="$PROJECT_DIR/.cursor/skills/teleport"
  )
else
  declare -A DESTS=()
  for k in "${!USER_DESTS[@]}"; do
    DESTS[$k]="${USER_DESTS[$k]}"
  done
fi

TARGETS=()
if [[ ${#FILTERS[@]} -gt 0 ]]; then
  for f in "${FILTERS[@]}"; do
    if [[ -n "${DESTS[$f]:-}" ]]; then
      TARGETS+=("$f")
    fi
  done
else
  for k in "${!DESTS[@]}"; do
    TARGETS+=("$k")
  done
fi

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  echo "error: no install targets selected." >&2
  exit 1
fi

for t in "${TARGETS[@]}"; do
  dest="${DESTS[$t]}"
  mkdir -p "$dest/scripts"
  cp "$SKILL_SRC/SKILL.md" "$dest/SKILL.md"
  cp "$SKILL_SRC/scripts/teleport-pack.sh" "$dest/scripts/teleport-pack.sh"
  cp "$SKILL_SRC/scripts/teleport-unpack.sh" "$dest/scripts/teleport-unpack.sh"
  chmod +x "$dest/scripts/teleport-pack.sh" "$dest/scripts/teleport-unpack.sh"
  echo "installed ($t): $dest"
done
