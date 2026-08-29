#!/usr/bin/env bash
# teleport-pack.sh — pack the current session into a portable bundle.
# usage: teleport-pack.sh [--name a-b] [--history FILE]... [--context FILE]...
#                          [--branch] [--push] [--max-mb N]
# --branch and --push are the same flag: both commit the change to a
# teleport/<name> branch and push it to 'origin'. requires a configured
# origin remote; a missing remote or a failed push is a hard error.
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  echo "usage: teleport-pack.sh [--name a-b] [--history FILE]... [--context FILE]... [--harness NAME] [--branch] [--push] [--max-mb N]" >&2
  echo "--harness explicitly sets the source harness label in MANIFEST.json (claude|cursor|codex|opencode|goose)." >&2
  echo "--branch and --push both commit + push a teleport/<name> branch to origin; requires an origin remote." >&2
  exit 1
}

NAME=""
HISTORY_ARGS=()
CONTEXT_ARGS=()
HARNESS_OVERRIDE=""
BRANCH_FLAG=false
MAX_MB=200

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      [[ $# -ge 2 ]] || usage
      NAME="$2"; shift 2 ;;
    --history)
      [[ $# -ge 2 ]] || usage
      HISTORY_ARGS+=("$2"); shift 2 ;;
    --context)
      [[ $# -ge 2 ]] || usage
      CONTEXT_ARGS+=("$2"); shift 2 ;;
    --harness)
      [[ $# -ge 2 ]] || usage
      HARNESS_OVERRIDE="$2"; shift 2 ;;
    --branch)
      BRANCH_FLAG=true; shift ;;
    --push)
      BRANCH_FLAG=true; shift ;;
    --max-mb)
      [[ $# -ge 2 ]] || usage
      MAX_MB="$2"; shift 2 ;;
    -h|--help)
      usage ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage ;;
  esac
done

if ! [[ "$MAX_MB" =~ ^[0-9]+$ ]] || [[ "$MAX_MB" -eq 0 ]]; then
  echo "error: --max-mb must be a positive integer, got: $MAX_MB" >&2
  exit 1
fi

if [[ -n "$NAME" ]] && ! [[ "$NAME" =~ ^[a-z0-9]+-[a-z0-9]+$ ]]; then
  echo "error: --name must match ^[a-z0-9]+-[a-z0-9]+\$ (it lands in a branch name and a filename), got: $NAME" >&2
  exit 1
fi

WARNINGS=()
warn() {
  echo "warning: $1" >&2
  WARNINGS+=("$1")
}

# --- step 1: resolve root ---------------------------------------------------
ORIG_CWD="$(pwd)"
GIT_PRESENT=false
ROOT="$ORIG_CWD"
if git rev-parse --show-toplevel >/dev/null 2>&1; then
  GIT_PRESENT=true
  ROOT="$(git rev-parse --show-toplevel)"
fi
cd "$ROOT"

# --- step 2: stop states ----------------------------------------------------
if [[ "$GIT_PRESENT" == true ]]; then
  MERGE_HEAD_PATH="$(git rev-parse --git-path MERGE_HEAD)"
  CHERRY_PICK_PATH="$(git rev-parse --git-path CHERRY_PICK_HEAD)"
  REBASE_MERGE_PATH="$(git rev-parse --git-path rebase-merge)"
  REBASE_APPLY_PATH="$(git rev-parse --git-path rebase-apply)"
  if [[ -f "$MERGE_HEAD_PATH" || -f "$CHERRY_PICK_PATH" || -e "$REBASE_MERGE_PATH" || -e "$REBASE_APPLY_PATH" ]]; then
    echo "error: a merge, rebase, or cherry-pick is in progress. finish or abort it first." >&2
    exit 1
  fi
  if [[ -n "$(git ls-files -u)" ]]; then
    echo "error: unmerged paths present. finish or abort the conflict first." >&2
    exit 1
  fi
fi

# --- step 3: validate the three md files ------------------------------------
TELEPORT_DIR="$ROOT/.teleport"
for f in SUMMARY.md FILES.md LEARNINGS.md; do
  p="$TELEPORT_DIR/$f"
  if [[ ! -s "$p" ]]; then
    echo "error: $p is missing or empty. write it before packing." >&2
    exit 1
  fi
done

# --- step 4: name generation -------------------------------------------------
ADJECTIVES=(rainbow amber brave calm daring eager fuzzy gentle happy jolly keen lively merry noble orange plucky quiet rapid sunny tidy upbeat vivid witty zesty bold bright cheerful cosmic crisp dreamy earnest festive golden humble icy jovial kind lucky mellow nimble opal peaceful quirky radiant silver tender urban velvet warm)
NOUNS=(unicorn falcon harbor meadow comet dragon ember forest galaxy horizon island jungle kestrel lagoon meteor nebula otter panther quartz river summit tiger valley willow zephyr badger canyon delta echo fjord glacier heron ibis jasper koala lantern mirage nectar oasis petal quokka raven sparrow thunder umbra violet walrus)

pick_name() {
  local a="${ADJECTIVES[$((RANDOM % ${#ADJECTIVES[@]}))]}"
  local n="${NOUNS[$((RANDOM % ${#NOUNS[@]}))]}"
  echo "${a}-${n}"
}

if [[ -n "$NAME" ]]; then
  ZIP_PATH="$ROOT/teleport-$NAME.zip"
  if [[ -e "$ZIP_PATH" ]]; then
    echo "error: $ZIP_PATH already exists. pick a different --name." >&2
    exit 1
  fi
else
  for _ in $(seq 1 100); do
    NAME="$(pick_name)"
    ZIP_PATH="$ROOT/teleport-$NAME.zip"
    [[ -e "$ZIP_PATH" ]] || break
    NAME=""
  done
  if [[ -z "$NAME" ]]; then
    echo "error: could not find a free bundle name after 100 tries." >&2
    exit 1
  fi
fi

# --- step 5: size preflight (before any object-store write) ----------------
if [[ "$GIT_PRESENT" == true ]]; then
  TOTAL_BYTES=$(
    total=0
    while IFS= read -r -d '' entry; do
      xy="${entry:0:2}"
      # R/C entries have two null-delimited fields: orig\0new\0
      # consume the original path so the next read gets the new path
      if [[ "${xy:0:1}" == "R" || "${xy:0:1}" == "C" ]]; then
        IFS= read -r -d '' _orig || true
        IFS= read -r -d '' path || continue
      else
        path="${entry:3}"
      fi
      if [[ -e "$path" ]]; then
        size=$(stat -c %s -- "$path" 2>/dev/null || echo 0)
        total=$(( total + size ))
      fi
    done < <(git status --porcelain -z --untracked-files=all)
    echo "$total"
  )
  CAP_BYTES=$(( MAX_MB * 1024 * 1024 ))
  if (( TOTAL_BYTES > CAP_BYTES )); then
    TOTAL_MB=$(( TOTAL_BYTES / 1024 / 1024 ))
    echo "error: changed + untracked files total ${TOTAL_MB}mb, over the ${MAX_MB}mb cap." >&2
    echo "commit or gitignore the large file, or raise the cap with --max-mb." >&2
    exit 1
  fi
fi

# --- step 6: history detection ----------------------------------------------
HISTORY_MODE="none"
HISTORY_HARNESS="none"
HISTORY_FILES=()

slugify() {
  echo "$1" | sed 's/[\/.]/-/g'
}

if [[ ${#HISTORY_ARGS[@]} -gt 0 ]]; then
  HISTORY_MODE="explicit"
  for h in "${HISTORY_ARGS[@]}"; do
    if [[ ! -e "$h" ]]; then
      echo "error: --history file not found: $h" >&2
      exit 1
    fi
    HISTORY_FILES+=("$h")
  done
  # best-effort harness label for an explicit file
  _hist_path="${HISTORY_FILES[0]}"
  case "$_hist_path" in
    *rollout-*.jsonl) HISTORY_HARNESS="codex" ;;
    */.goose/*|*/.config/goose/*) HISTORY_HARNESS="goose" ;;
    */.opencode/*) HISTORY_HARNESS="opencode" ;;
    */.cursor/*) HISTORY_HARNESS="cursor" ;;
    */.claude/*) HISTORY_HARNESS="claude" ;;
    *.jsonl) HISTORY_HARNESS="claude" ;;  # fallback for generic jsonl
    *) HISTORY_HARNESS="unknown" ;;
  esac
else
  EXACT_FOUND=""
  if [[ -n "${CLAUDE_CODE_SESSION_ID:-}" ]]; then
    MATCHES="$(find "$HOME/.claude/projects" -name "${CLAUDE_CODE_SESSION_ID}.jsonl" 2>/dev/null || true)"
    COUNT="$(printf '%s\n' "$MATCHES" | grep -c . || true)"
    if [[ "$COUNT" -eq 1 ]]; then
      EXACT_FOUND="$MATCHES"
    elif [[ "$COUNT" -gt 1 ]]; then
      echo "error: multiple history files found for session id $CLAUDE_CODE_SESSION_ID:" >&2
      printf '%s\n' "$MATCHES" | while IFS= read -r c; do echo "  $c" >&2; done
      echo "pass --history <file> to pick one." >&2
      exit 1
    fi
  fi

  if [[ -n "$EXACT_FOUND" ]]; then
    HISTORY_FILES=("$EXACT_FOUND")
    HISTORY_MODE="exact"
    HISTORY_HARNESS="claude"
  else
    SLUG="$(slugify "$ROOT")"
    CANDIDATES=()

    if [[ -d "$HOME/.claude/projects/$SLUG" ]]; then
      while IFS= read -r -d '' f; do
        CANDIDATES+=("$f")
      done < <(find "$HOME/.claude/projects/$SLUG" -maxdepth 1 -name '*.jsonl' -print0 2>/dev/null)
    fi

    CODEX_MATCHES=()
    if [[ -d "$HOME/.codex/sessions" ]]; then
      # optimize: sort by mtime descending and stop at first match
      while IFS= read -r -d '' f; do
        cwd="$(head -n 1 "$f" 2>/dev/null | jq -r '.payload.cwd // empty' 2>/dev/null || true)"
        if [[ "$cwd" == "$ROOT" ]]; then
          CODEX_MATCHES+=("$f")
          break  # newest matching session is sufficient
        fi
      done < <(find "$HOME/.codex/sessions" -type f -name 'rollout-*.jsonl' -printf '%T@\t%p\0' 2>/dev/null | sort -rz -t$'\t' -k1,1 | cut -z -f2-)
    fi

    CURSOR_MATCHES=()
    if [[ -d "$HOME/.cursor/projects" ]]; then
      CURSOR_SLUG="$(echo "$ROOT" | sed 's|/|-|g')"
      if [[ -d "$HOME/.cursor/projects/$CURSOR_SLUG" ]]; then
        while IFS= read -r -d '' f; do
          CURSOR_MATCHES+=("$f")
        done < <(find "$HOME/.cursor/projects/$CURSOR_SLUG" -maxdepth 1 -name '*.jsonl' -print0 2>/dev/null)
      fi
    fi

    OPENCODE_MATCHES=()
    if [[ -d "$HOME/.opencode/sessions" ]]; then
      while IFS= read -r -d '' f; do
        cwd="$(head -n 1 "$f" 2>/dev/null | jq -r '.cwd // .payload.cwd // empty' 2>/dev/null || true)"
        if [[ "$cwd" == "$ROOT" ]]; then
          OPENCODE_MATCHES+=("$f")
        fi
      done < <(find "$HOME/.opencode/sessions" -type f -name '*.jsonl' -print0 2>/dev/null)
    fi

    GOOSE_MATCHES=()
    for _goose_dir in "$HOME/.config/goose/sessions" "$HOME/.goose/sessions"; do
      if [[ -d "$_goose_dir" ]]; then
        while IFS= read -r -d '' f; do
          cwd="$(head -n 1 "$f" 2>/dev/null | jq -r '.working_directory // .cwd // empty' 2>/dev/null || true)"
          if [[ "$cwd" == "$ROOT" ]]; then
            GOOSE_MATCHES+=("$f")
          fi
        done < <(find "$_goose_dir" -type f -name '*.jsonl' -print0 2>/dev/null)
      fi
    done

    ALL_CANDS=("${CANDIDATES[@]}" "${CODEX_MATCHES[@]}" "${CURSOR_MATCHES[@]}" "${OPENCODE_MATCHES[@]}" "${GOOSE_MATCHES[@]}")

    if [[ ${#ALL_CANDS[@]} -eq 1 ]]; then
      HISTORY_FILES=("${ALL_CANDS[0]}")
      HISTORY_MODE="heuristic"
      _matched="${ALL_CANDS[0]}"
      case "$_matched" in
        */.claude/*) HISTORY_HARNESS="claude" ;;
        */.codex/*) HISTORY_HARNESS="codex" ;;
        */.cursor/*) HISTORY_HARNESS="cursor" ;;
        */.opencode/*) HISTORY_HARNESS="opencode" ;;
        */.goose/*|*/.config/goose/*) HISTORY_HARNESS="goose" ;;
        *) HISTORY_HARNESS="unknown" ;;
      esac
    elif [[ ${#ALL_CANDS[@]} -gt 1 ]]; then
      echo "error: multiple history candidates found for this workdir:" >&2
      for c in "${ALL_CANDS[@]}"; do
        echo "  $c" >&2
      done
      echo "pass --history <file> to pick one." >&2
      exit 1
    else
      HISTORY_MODE="none"
      HISTORY_HARNESS="none"
      warn "no history auto-detected. for cursor/opencode pass --history <file>."
    fi
  fi
fi

SOURCE_HARNESS="unknown"
if [[ -n "$HARNESS_OVERRIDE" ]]; then
  SOURCE_HARNESS="$HARNESS_OVERRIDE"
elif [[ -n "${CLAUDE_CODE_SESSION_ID:-}" ]]; then
  SOURCE_HARNESS="claude"
elif [[ "$HISTORY_HARNESS" != "none" && "$HISTORY_HARNESS" != "unknown" ]]; then
  SOURCE_HARNESS="$HISTORY_HARNESS"
fi

# --- step 7 (part 1): dirty submodules (run before the temp index exists) --
SUBMODULES_DIRTY=()
if [[ "$GIT_PRESENT" == true && -f "$ROOT/.gitmodules" ]]; then
  while IFS= read -r name; do
    [[ -n "$name" ]] && SUBMODULES_DIRTY+=("$name")
  done < <(env -u GIT_INDEX_FILE git submodule foreach --quiet 'if [ -n "$(git status --porcelain | head -1)" ]; then echo "$name"; fi' 2>/dev/null || true)
  if [[ ${#SUBMODULES_DIRTY[@]} -gt 0 ]]; then
    warn "dirty submodules not packed: ${SUBMODULES_DIRTY[*]}"
  fi
fi

# --- step 7 (part 2): temp index, patch, tree ------------------------------
UNBORN=true
HEAD_SHA=""
CURRENT_BRANCH=""
TREE_SHA=""
TMP_PATCH=""
PATCH_NONEMPTY=false
TRANSPORT="none"
TELEPORT_BRANCH=""
REMOTE_URL=""
REMOTES_JSON="[]"
STATUS_JSON="[]"

if [[ "$GIT_PRESENT" == true ]]; then
  if git rev-parse --verify -q HEAD >/dev/null 2>&1; then
    UNBORN=false
    HEAD_SHA="$(git rev-parse HEAD)"
  fi
  CURRENT_BRANCH="$(git symbolic-ref --short -q HEAD || true)"
  REMOTE_URL="$(git remote get-url origin 2>/dev/null || true)"
  REMOTES_JSON="$(git remote -v 2>/dev/null | awk '{print $1" "$2}' | sort -u | jq -R -s 'split("\n") | map(select(length > 0))')"

  # capture real status before GIT_INDEX_FILE is redirected to the temp index below
  STATUS_JSON="$(git status --porcelain 2>/dev/null | jq -R -s 'split("\n") | map(select(length > 0))')"

  if [[ "$BRANCH_FLAG" == true && -z "$REMOTE_URL" ]]; then
    echo "error: --branch (and --push) create a branch and push it to 'origin', but no origin remote is configured." >&2
    echo "re-run without --branch for patch transport." >&2
    exit 1
  fi

  TMP_INDEX="$(mktemp)"
  rm -f "$TMP_INDEX"
  TMP_PATCH="$(mktemp)"
  export GIT_INDEX_FILE="$TMP_INDEX"
  cleanup_index() { rm -f "$TMP_INDEX" "$TMP_PATCH"; }
  trap cleanup_index EXIT

  if [[ "$UNBORN" == false ]]; then
    git read-tree HEAD
  fi
  git add -A
  if [[ "$UNBORN" == false ]]; then
    # restore .teleport / teleport-*.zip to their HEAD state (or drop them if
    # HEAD has none), so a tracked bundle artifact never looks deleted here.
    git reset -q HEAD -- .teleport 'teleport-*.zip'
  else
    # unborn HEAD: nothing is tracked yet, so there is nothing to restore to.
    git rm -r --cached --ignore-unmatch -q -- .teleport 'teleport-*.zip'
  fi

  EMPTY_TREE="$(git hash-object -t tree /dev/null)"
  if [[ "$UNBORN" == true ]]; then
    DIFF_BASE="$EMPTY_TREE"
  else
    DIFF_BASE="HEAD"
  fi
  git diff --cached --binary --full-index "$DIFF_BASE" > "$TMP_PATCH"
  [[ -s "$TMP_PATCH" ]] && PATCH_NONEMPTY=true

  TREE_SHA="$(git write-tree)"

  if [[ "$BRANCH_FLAG" == true ]]; then
    TRANSPORT="branch"
    TELEPORT_BRANCH="teleport/$NAME"
  elif [[ "$PATCH_NONEMPTY" == true ]]; then
    TRANSPORT="patch"
  else
    TRANSPORT="none"
  fi
fi

# --- staging: assemble the bundle directory ---------------------------------
STAGE_DIR="$(mktemp -d)"
BUNDLE_DIR="$STAGE_DIR/teleport-$NAME"
mkdir -p "$BUNDLE_DIR" "$BUNDLE_DIR/history" "$BUNDLE_DIR/context" "$BUNDLE_DIR/_teleport"

if [[ "$GIT_PRESENT" == true ]]; then
  trap 'rm -f "$TMP_INDEX" "$TMP_PATCH"; rm -rf "$STAGE_DIR"' EXIT
else
  trap 'rm -rf "$STAGE_DIR"' EXIT
fi

cp "$TELEPORT_DIR/SUMMARY.md" "$BUNDLE_DIR/SUMMARY.md"
cp "$TELEPORT_DIR/FILES.md" "$BUNDLE_DIR/FILES.md"
cp "$TELEPORT_DIR/LEARNINGS.md" "$BUNDLE_DIR/LEARNINGS.md"

for c in "${CONTEXT_ARGS[@]:-}"; do
  [[ -n "$c" ]] || continue
  if [[ ! -f "$c" ]]; then
    echo "error: --context file not found: $c" >&2
    exit 1
  fi
  base="$(basename "$c")"
  dest="$BUNDLE_DIR/context/$base"
  if [[ -e "$dest" ]]; then
    echo "error: duplicate --context basename: $base" >&2
    exit 1
  fi
  cp "$c" "$dest"
done

HISTORY_COPIED=()
for h in "${HISTORY_FILES[@]:-}"; do
  [[ -n "$h" ]] || continue
  base="$(basename "$h")"
  dest="$BUNDLE_DIR/history/$base"
  n=1
  while [[ -e "$dest" ]]; do
    dest="$BUNDLE_DIR/history/${n}_${base}"
    n=$(( n + 1 ))
  done
  cp -p "$h" "$dest"
  HISTORY_COPIED+=("$dest")
  for side in wal shm; do
    if [[ -e "${h}-${side}" ]]; then
      cp -p "${h}-${side}" "${dest}-${side}"
    fi
  done
  if [[ "$h" == *.db || "$h" == *.sqlite ]]; then
    warn "cannot scan sqlite history for secrets: $base — review before shipping"
  fi
done

PATCH_SIZE=0
if [[ "$TRANSPORT" == "patch" ]]; then
  cp "$TMP_PATCH" "$BUNDLE_DIR/uncommitted.patch"
  PATCH_SIZE=$(stat -c %s "$BUNDLE_DIR/uncommitted.patch")
fi

# --- step 8: RESUME.md -------------------------------------------------------
if [[ "$TRANSPORT" == "branch" ]]; then
  RESTORE_STEPS="the bundle used the branch transport. the uncommitted change is committed and pushed to \`origin\` on branch \`$TELEPORT_BRANCH\`.

1. fetch it: \`git fetch origin $TELEPORT_BRANCH\` (or clone fresh: \`git clone $REMOTE_URL\`).
2. checkout the branch: \`git checkout $TELEPORT_BRANCH\`.
3. do NOT apply \`uncommitted.patch\` — there is none in this bundle. the branch already contains the change."
elif [[ "$TRANSPORT" == "patch" ]]; then
  RESTORE_STEPS="the bundle used the patch transport. head was at \`$HEAD_SHA\` on branch \`$CURRENT_BRANCH\` when packed.

1. get the repo to \`$HEAD_SHA\` (clone from \`$REMOTE_URL\` and \`git checkout $HEAD_SHA\`, or fetch it into an existing clone).
2. check the patch applies clean: \`git apply --check uncommitted.patch\`.
3. if the check passes, apply it: \`git apply uncommitted.patch\`.
4. if the check fails, stop and ask the user before forcing anything."
else
  RESTORE_STEPS="the tree was clean when packed. head was at \`${HEAD_SHA:-none, unborn}\` on branch \`$CURRENT_BRANCH\`.
there is no patch to apply. get the repo to that head and continue."
fi

cat > "$BUNDLE_DIR/RESUME.md" <<EOF
# resume: teleport-$NAME

## 1. read first

read SUMMARY.md, FILES.md, and LEARNINGS.md in full before you do anything else.
they hold the goal, the work done so far, and the gotchas paid for by the last session.

## 2. restore the workspace

$RESTORE_STEPS

## 3. caveats

- submodule content is not packed. if MANIFEST.json lists a submodule under \`submodules_dirty\`, its uncommitted state is missing here — recheck it by hand.
- symlinks in the patch need \`core.symlinks=true\` on the target machine, or they land as text files.

## 4. history/

\`history/\` holds raw prior-session history, best effort. grep it on demand for extra context.
do not try to import it into the new harness — it is not a supported format for that.

## 5. when a premise fails

if the remote is missing, the head sha is not found, or the patch conflicts: stop and ask the user.
do not improvise a fix.
EOF

# --- step 9: secret scan (always before any git branch / git push) ----------
PATTERN_FILE="$(mktemp)"
if [[ "$GIT_PRESENT" == true ]]; then
  trap 'rm -f "$TMP_INDEX" "$TMP_PATCH" "$PATTERN_FILE"; rm -rf "$STAGE_DIR"' EXIT
else
  trap 'rm -f "$PATTERN_FILE"; rm -rf "$STAGE_DIR"' EXIT
fi
cat > "$PATTERN_FILE" <<'EOF'
-----BEGIN( RSA| EC| OPENSSH)? PRIVATE KEY-----
AKIA[0-9A-Z]{16}
(api[_-]?key|secret|token|password)[[:space:]]*[:=][[:space:]]*['\''"][^'\''"]{8,}
EOF

SCAN_PATHS=("$BUNDLE_DIR/SUMMARY.md" "$BUNDLE_DIR/FILES.md" "$BUNDLE_DIR/LEARNINGS.md")
SCAN_LABELS=("SUMMARY.md" "FILES.md" "LEARNINGS.md")
# scan the diff itself, not just the staged copy — this also covers branch
# transport, which never gets an uncommitted.patch file in the bundle.
if [[ -n "$TMP_PATCH" && -s "$TMP_PATCH" ]]; then
  SCAN_PATHS+=("$TMP_PATCH")
  SCAN_LABELS+=("uncommitted.patch")
fi
while IFS= read -r -d '' f; do
  SCAN_PATHS+=("$f")
  SCAN_LABELS+=("context/$(basename "$f")")
done < <(find "$BUNDLE_DIR/context" -type f -print0 2>/dev/null)
while IFS= read -r -d '' f; do
  if [[ "$f" == *.jsonl ]]; then
    SCAN_PATHS+=("$f")
    SCAN_LABELS+=("history/$(basename "$f")")
  fi
done < <(find "$BUNDLE_DIR/history" -type f -print0 2>/dev/null)

for i in "${!SCAN_PATHS[@]}"; do
  if grep -aEqf "$PATTERN_FILE" -- "${SCAN_PATHS[$i]}" 2>/dev/null; then
    warn "possible secret pattern in ${SCAN_LABELS[$i]} — review before shipping"
  fi
done
rm -f "$PATTERN_FILE"

# --- branch creation + push (only after the secret scan has printed) --------
if [[ "$TRANSPORT" == "branch" ]]; then
  if [[ "$UNBORN" == true ]]; then
    COMMIT_SHA="$(git commit-tree "$TREE_SHA" -m "teleport $NAME")"
  else
    COMMIT_SHA="$(git commit-tree "$TREE_SHA" -p HEAD -m "teleport $NAME")"
  fi
  git branch "$TELEPORT_BRANCH" "$COMMIT_SHA"
  if ! git push origin "$TELEPORT_BRANCH"; then
    echo "error: push of $TELEPORT_BRANCH to origin failed. re-run without --branch for patch transport." >&2
    exit 1
  fi
fi

# --- step 10: bootstrap copy --------------------------------------------------
cp "$SCRIPT_DIR/teleport-unpack.sh" "$BUNDLE_DIR/_teleport/teleport-unpack.sh"
cp "$SKILL_DIR/SKILL.md" "$BUNDLE_DIR/_teleport/SKILL.md"
chmod +x "$BUNDLE_DIR/_teleport/teleport-unpack.sh"

# --- step 11: MANIFEST.json ---------------------------------------------------
SUBMODULES_JSON="$(printf '%s\n' "${SUBMODULES_DIRTY[@]:-}" | jq -R -s 'split("\n") | map(select(length > 0))')"
HISTORY_FILES_JSON="$(printf '%s\n' "${HISTORY_COPIED[@]:-}" | xargs -I{} -n1 basename {} 2>/dev/null | jq -R -s 'split("\n") | map(select(length > 0))')"
WARNINGS_JSON="$(printf '%s\n' "${WARNINGS[@]:-}" | jq -R -s 'split("\n") | map(select(length > 0))')"

CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

jq -n \
  --argjson bundle_format 1 \
  --arg name "$NAME" \
  --arg created_at "$CREATED_AT" \
  --arg host "$(hostname)" \
  --arg user "$(whoami)" \
  --arg cwd "$ORIG_CWD" \
  --arg harness "$SOURCE_HARNESS" \
  --argjson git_present "$GIT_PRESENT" \
  --arg repo_root "$ROOT" \
  --arg remote "$REMOTE_URL" \
  --argjson remotes "$REMOTES_JSON" \
  --arg branch "$CURRENT_BRANCH" \
  --arg head_sha "$HEAD_SHA" \
  --arg tree_sha "$TREE_SHA" \
  --arg teleport_branch "$TELEPORT_BRANCH" \
  --argjson status_porcelain "$STATUS_JSON" \
  --argjson submodules_dirty "$SUBMODULES_JSON" \
  --arg transport "$TRANSPORT" \
  --arg history_mode "$HISTORY_MODE" \
  --arg history_harness "$HISTORY_HARNESS" \
  --argjson history_files "$HISTORY_FILES_JSON" \
  --argjson warnings "$WARNINGS_JSON" \
  '{
    bundle_format: $bundle_format,
    name: $name,
    created_at: $created_at,
    source: { host: $host, user: $user, cwd: $cwd, harness: $harness },
    git: {
      present: $git_present,
      repo_root: (if $git_present then $repo_root else null end),
      remote: (if $remote == "" then null else $remote end),
      remotes: $remotes,
      branch: (if $branch == "" then null else $branch end),
      head_sha: (if $head_sha == "" then null else $head_sha end),
      tree_sha: (if $tree_sha == "" then null else $tree_sha end),
      teleport_branch: (if $teleport_branch == "" then null else $teleport_branch end),
      status_porcelain: $status_porcelain,
      submodules_dirty: $submodules_dirty
    },
    transport: $transport,
    history: { mode: $history_mode, harness: $history_harness, files: $history_files },
    warnings: $warnings
  }' > "$BUNDLE_DIR/MANIFEST.json"

# --- zip creation and verification -------------------------------------------
# build to a temp path on the same filesystem as ZIP_PATH, verify, then
# atomically rename into place — a failed create never leaves a partial
# zip at the final path.
TMP_ZIP="$ZIP_PATH.tmp.$$"
if [[ "$GIT_PRESENT" == true ]]; then
  trap 'rm -f "$TMP_INDEX" "$TMP_PATCH" "$TMP_ZIP"; rm -rf "$STAGE_DIR"' EXIT
else
  trap 'rm -f "$TMP_ZIP"; rm -rf "$STAGE_DIR"' EXIT
fi

(cd "$STAGE_DIR" && python3 -m zipfile -c "$TMP_ZIP" "teleport-$NAME")

if ! python3 -m zipfile -t "$TMP_ZIP" >/dev/null; then
  echo "error: zip verification failed for $TMP_ZIP" >&2
  exit 1
fi

mv "$TMP_ZIP" "$ZIP_PATH"

# --- final report --------------------------------------------------------------
if [[ ${#HISTORY_COPIED[@]} -gt 0 ]]; then
  for h in "${HISTORY_COPIED[@]}"; do
    src_mtime=""
    if [[ -e "${h}" ]]; then
      src_mtime="$(date -u -d "@$(stat -c %Y "$h")" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
    fi
    echo "history: $(basename "$h") (mtime: ${src_mtime:-unknown}, mode: $HISTORY_MODE)"
  done
else
  echo "history: none (mode: $HISTORY_MODE)"
fi
echo "patch: ${PATCH_SIZE} bytes"
for w in "${WARNINGS[@]:-}"; do
  [[ -n "$w" ]] && echo "warning: $w"
done
echo "bundle: $ZIP_PATH"
