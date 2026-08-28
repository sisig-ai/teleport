#!/usr/bin/env bash
# teleport-unpack.sh — extract a teleport bundle and report its state.
# usage: teleport-unpack.sh <zip> [--dir DIR]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "usage: teleport-unpack.sh <zip> [--dir DIR]" >&2
  exit 1
}

ZIP_PATH=""
DEST_DIR="$(pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)
      [[ $# -ge 2 ]] || usage
      DEST_DIR="$2"; shift 2 ;;
    -h|--help)
      usage ;;
    *)
      if [[ -z "$ZIP_PATH" ]]; then
        ZIP_PATH="$1"; shift
      else
        echo "error: unknown argument: $1" >&2
        usage
      fi
      ;;
  esac
done

[[ -n "$ZIP_PATH" ]] || usage
if [[ ! -f "$ZIP_PATH" ]]; then
  echo "error: zip file not found: $ZIP_PATH" >&2
  exit 1
fi
ZIP_PATH="$(cd "$(dirname "$ZIP_PATH")" && pwd)/$(basename "$ZIP_PATH")"

mkdir -p "$DEST_DIR"
DEST_DIR="$(cd "$DEST_DIR" && pwd)"

if command -v unzip >/dev/null 2>&1; then
  if ! unzip -t "$ZIP_PATH" >/dev/null; then
    echo "error: zip integrity check failed (unzip -t): $ZIP_PATH" >&2
    exit 1
  fi
else
  echo "warning: unzip not found, skipping unzip -t integrity check" >&2
fi

# always run the python integrity check, regardless of unzip's availability.
if ! python3 -m zipfile -t "$ZIP_PATH" >/dev/null; then
  echo "error: zip integrity check failed (python3 -m zipfile -t): $ZIP_PATH" >&2
  exit 1
fi

PYEXTRACT="$(mktemp)"
cat > "$PYEXTRACT" <<'PYEOF'
import sys, zipfile, posixpath

zip_path, dest_dir = sys.argv[1], sys.argv[2]

with zipfile.ZipFile(zip_path) as zf:
    seen = set()
    for info in zf.infolist():
        name = info.filename
        if name.endswith('/'):
            continue
        norm = posixpath.normpath(name)
        parts = norm.split('/')
        if norm.startswith('/') or '..' in parts:
            print(f"error: unsafe path in zip member: {name}", file=sys.stderr)
            sys.exit(1)
        if norm in seen:
            print(f"error: duplicate path in zip member: {name}", file=sys.stderr)
            sys.exit(1)
        seen.add(norm)
        mode = (info.external_attr >> 16) & 0o170000
        if mode == 0o120000:
            print(f"error: symlink member rejected: {name}", file=sys.stderr)
            sys.exit(1)
    zf.extractall(dest_dir)
PYEOF

if ! python3 "$PYEXTRACT" "$ZIP_PATH" "$DEST_DIR"; then
  rm -f "$PYEXTRACT"
  exit 1
fi
rm -f "$PYEXTRACT"

MANIFEST_PATH="$(find "$DEST_DIR" -maxdepth 2 -name MANIFEST.json -print -quit)"
if [[ -z "$MANIFEST_PATH" ]]; then
  echo "error: MANIFEST.json not found after extraction." >&2
  exit 1
fi
BUNDLE_DIR="$(dirname "$MANIFEST_PATH")"

echo "--- bundle summary ---"
jq -r '
  "name: \(.name)",
  "created_at: \(.created_at)",
  "source host: \(.source.host)",
  "source user: \(.source.user)",
  "source cwd: \(.source.cwd)",
  "git remote: \(.git.remote // "none")",
  "git branch: \(.git.branch // "none")",
  "git head: \(.git.head_sha // "none")",
  "transport: \(.transport)",
  "history mode: \(.history.mode)",
  "submodules dirty: \(.git.submodules_dirty | join(", "))"
' "$MANIFEST_PATH"

MANIFEST_HEAD="$(jq -r '.git.head_sha // empty' "$MANIFEST_PATH")"
if git rev-parse --show-toplevel >/dev/null 2>&1 && [[ -n "$MANIFEST_HEAD" ]]; then
  LOCAL_HEAD="$(git rev-parse HEAD 2>/dev/null || true)"
  if [[ "$LOCAL_HEAD" == "$MANIFEST_HEAD" ]]; then
    echo "git head: local matches manifest ($MANIFEST_HEAD)"
  else
    echo "git head: local (${LOCAL_HEAD:-none}) does NOT match manifest ($MANIFEST_HEAD)"
  fi
fi

echo "--- next steps ---"
echo "read $BUNDLE_DIR/RESUME.md first."

TRANSPORT="$(jq -r '.transport' "$MANIFEST_PATH")"
TELEPORT_BRANCH="$(jq -r '.git.teleport_branch // empty' "$MANIFEST_PATH")"
case "$TRANSPORT" in
  branch)
    echo "restore command (do not run automatically): git fetch origin $TELEPORT_BRANCH && git checkout $TELEPORT_BRANCH"
    ;;
  patch)
    if [[ -n "$MANIFEST_HEAD" ]]; then
      echo "restore command (do not run automatically): git checkout $MANIFEST_HEAD && git apply --check $BUNDLE_DIR/uncommitted.patch && git apply $BUNDLE_DIR/uncommitted.patch"
    else
      echo "restore command (do not run automatically): source repo had no commits (unborn head) — git init the target, then: git apply --check $BUNDLE_DIR/uncommitted.patch && git apply $BUNDLE_DIR/uncommitted.patch"
    fi
    ;;
  *)
    echo "restore command: none — the tree was clean at head $MANIFEST_HEAD."
    ;;
esac
