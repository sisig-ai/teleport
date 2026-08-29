#!/usr/bin/env bash
# install.sh — install the teleport skill for one or more harnesses.
# usage: install.sh [--project DIR] [harness ...]
# harness names: claude cursor codex opencode goose
# when no harness is specified, installs to ALL detected harnesses on this machine.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_SRC="$SCRIPT_DIR/skill"

usage() {
  echo "usage: install.sh [--project DIR] [harness ...]" >&2
  echo "harness names: claude cursor codex opencode goose" >&2
  echo "with no arguments, auto-detects and installs to all available harnesses." >&2
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
    claude|cursor|codex|opencode|goose)
      FILTERS+=("$1"); shift ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage ;;
  esac
done

if [[ ! -f "$SKILL_SRC/SKILL.md" ]]; then
  echo "error: $SKILL_SRC/SKILL.md not found. run this from the teleport repo root." >&2
  exit 1
fi

# --- user-level destination map (all supported harnesses) -------------------
declare -A USER_DESTS=(
  [claude]="$HOME/.claude/skills/teleport"
  [cursor]="$HOME/.cursor/skills/teleport"
  [codex]="$HOME/.codex/skills/teleport"
  [opencode]="$HOME/.config/opencode/skills/teleport"
  [goose]="$HOME/.config/goose/skills/teleport"
)

# --- detection heuristics: does this machine have the harness? --------------
detect_harness() {
  local h="$1"
  case "$h" in
    claude)   command -v claude >/dev/null 2>&1 || [[ -d "$HOME/.claude" ]] ;;
    cursor)   command -v cursor >/dev/null 2>&1 || [[ -d "$HOME/.cursor" ]] ;;
    codex)    command -v codex >/dev/null 2>&1 || [[ -d "$HOME/.codex" ]] ;;
    opencode) command -v opencode >/dev/null 2>&1 || [[ -d "$HOME/.opencode" ]] || [[ -d "$HOME/.config/opencode" ]] ;;
    goose)    command -v goose >/dev/null 2>&1 || [[ -d "$HOME/.config/goose" ]] || [[ -d "$HOME/.goose" ]] ;;
    *)        return 1 ;;
  esac
}

# --- build target list ------------------------------------------------------
if [[ -n "$PROJECT_DIR" ]]; then
  # project-level installs only verified for claude and cursor layouts
  if [[ ${#FILTERS[@]} -gt 0 ]]; then
    for f in "${FILTERS[@]}"; do
      if [[ "$f" != "claude" && "$f" != "cursor" ]]; then
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
  # explicit harness list: use as-is (user knows what they want)
  for f in "${FILTERS[@]}"; do
    if [[ -n "${DESTS[$f]:-}" ]]; then
      TARGETS+=("$f")
    else
      echo "warning: skipping '$f' — no install destination configured." >&2
    fi
  done
else
  # auto-detect: only install to harnesses present on this machine
  for k in "${!DESTS[@]}"; do
    if detect_harness "$k"; then
      TARGETS+=("$k")
    fi
  done
fi

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  echo "error: no install targets selected. specify a harness or ensure at least one is installed." >&2
  echo "available: claude cursor codex opencode goose" >&2
  exit 1
fi

# --- install ----------------------------------------------------------------
INSTALLED=0
for t in "${TARGETS[@]}"; do
  dest="${DESTS[$t]}"
  mkdir -p "$dest/scripts"
  cp "$SKILL_SRC/SKILL.md" "$dest/SKILL.md"
  cp "$SKILL_SRC/scripts/teleport-pack.sh" "$dest/scripts/teleport-pack.sh"
  cp "$SKILL_SRC/scripts/teleport-unpack.sh" "$dest/scripts/teleport-unpack.sh"
  chmod +x "$dest/scripts/teleport-pack.sh" "$dest/scripts/teleport-unpack.sh"
  echo "✓ installed ($t): $dest"
  INSTALLED=$((INSTALLED + 1))
done

echo ""
echo "teleport skill installed to $INSTALLED harness(es)."
echo "run '/teleport' or 'teleport this session' in any installed harness to get started."