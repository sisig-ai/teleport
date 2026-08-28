#!/usr/bin/env bash
# smoke.sh — 12 assertions against teleport-pack.sh and teleport-unpack.sh.
set -uo pipefail

TELEPORT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACK="$TELEPORT_ROOT/skill/scripts/teleport-pack.sh"
UNPACK="$TELEPORT_ROOT/skill/scripts/teleport-unpack.sh"

SANDBOX="$(mktemp -d)/teleport smoke"
mkdir -p "$SANDBOX"
cleanup() { rm -rf "$(dirname "$SANDBOX")"; }
trap cleanup EXIT

FAILS=0
pass() { echo "pass: $1"; }
fail() { echo "fail: $1"; FAILS=$((FAILS + 1)); }

FAKE_HISTORY="$SANDBOX/fake-history.jsonl"
echo '{"type":"session_meta"}' > "$FAKE_HISTORY"

make_fixture_repo() {
  local dir="$1"
  mkdir -p "$dir/sub"
  (
    cd "$dir"
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name "test"
    echo "committed content" > committed.txt
    echo "to be deleted" > deleted.txt
    git add committed.txt deleted.txt
    git commit -q -m "init"
    echo "modified content" >> committed.txt
    rm deleted.txt
    echo "untracked content" > untracked.txt
  )
}

write_md_files() {
  local dir="$1"
  mkdir -p "$dir/.teleport"
  printf 'goal: smoke test\nwhat was done: fixture setup\n' > "$dir/.teleport/SUMMARY.md"
  printf 'committed.txt: modified\nuntracked.txt: added\n' > "$dir/.teleport/FILES.md"
  printf 'nothing learned yet, this is a fixture.\n' > "$dir/.teleport/LEARNINGS.md"
}

# ---------------------------------------------------------------------------
# 1. patch from the bundle applies clean to a fresh clone
# ---------------------------------------------------------------------------
REPO1="$SANDBOX/repo one/proj"
make_fixture_repo "$REPO1"
write_md_files "$REPO1"

if (cd "$REPO1" && "$PACK" --history "$FAKE_HISTORY" --name test1-patch >"$SANDBOX/t1.out" 2>&1); then
  ZIP1="$REPO1/teleport-test1-patch.zip"
  UNPACK1="$SANDBOX/unpack1"
  if "$UNPACK" "$ZIP1" --dir "$UNPACK1" >"$SANDBOX/t1-unpack.out" 2>&1; then
    BUNDLE1="$UNPACK1/teleport-test1-patch"
    CLONE1="$SANDBOX/clone one"
    git clone -q "$REPO1" "$CLONE1" 2>"$SANDBOX/t1-clone.out"
    (
      cd "$CLONE1"
      git apply --check "$BUNDLE1/uncommitted.patch" &&
      git apply "$BUNDLE1/uncommitted.patch"
    ) >"$SANDBOX/t1-apply.out" 2>&1
    APPLY_STATUS=$?
    if [[ "$APPLY_STATUS" -eq 0 ]] \
      && diff -q "$CLONE1/committed.txt" "$REPO1/committed.txt" >/dev/null \
      && diff -q "$CLONE1/untracked.txt" "$REPO1/untracked.txt" >/dev/null \
      && [[ ! -e "$CLONE1/deleted.txt" ]]; then
      pass "1. patch applies clean, contents match, deletion included"
    else
      fail "1. patch applies clean, contents match, deletion included (see $SANDBOX/t1-apply.out)"
    fi
  else
    fail "1. unpack of bundle failed (see $SANDBOX/t1-unpack.out)"
  fi
else
  fail "1. pack failed (see $SANDBOX/t1.out)"
fi

# ---------------------------------------------------------------------------
# 2. pack exits nonzero when LEARNINGS.md is empty
# ---------------------------------------------------------------------------
REPO2="$SANDBOX/repo2"
make_fixture_repo "$REPO2"
write_md_files "$REPO2"
: > "$REPO2/.teleport/LEARNINGS.md"

if (cd "$REPO2" && "$PACK" --history "$FAKE_HISTORY" --name test2-empty >"$SANDBOX/t2.out" 2>&1); then
  fail "2. pack should fail on empty LEARNINGS.md"
else
  pass "2. pack fails on empty LEARNINGS.md"
fi

# ---------------------------------------------------------------------------
# 3. pack exits nonzero when LEARNINGS.md is missing entirely
# ---------------------------------------------------------------------------
REPO3M="$SANDBOX/repo3-missing"
make_fixture_repo "$REPO3M"
write_md_files "$REPO3M"
rm -f "$REPO3M/.teleport/LEARNINGS.md"

if (cd "$REPO3M" && "$PACK" --history "$FAKE_HISTORY" --name test3-missing >"$SANDBOX/t3m.out" 2>&1); then
  fail "3. pack should fail when LEARNINGS.md is missing"
else
  pass "3. pack fails when LEARNINGS.md is missing"
fi

# ---------------------------------------------------------------------------
# 4. --branch (requires a remote, now always pushes): commit tree has the
#    change, working tree unchanged, RESUME.md has the branch path and not
#    the patch-apply step
# ---------------------------------------------------------------------------
REPO4="$SANDBOX/repo4"
BARE4="$SANDBOX/bare4.git"
git init -q --bare -b main "$BARE4"
make_fixture_repo "$REPO4"
write_md_files "$REPO4"
git -C "$REPO4" remote add origin "$BARE4"
STATUS_BEFORE="$(cd "$REPO4" && git status --porcelain)"
HEAD_BEFORE="$(cd "$REPO4" && git rev-parse HEAD)"

if (cd "$REPO4" && "$PACK" --branch --history "$FAKE_HISTORY" --name test4-branch >"$SANDBOX/t4.out" 2>&1); then
  STATUS_AFTER="$(cd "$REPO4" && git status --porcelain | grep -v 'teleport-test4-branch\.zip')"
  HEAD_AFTER="$(cd "$REPO4" && git rev-parse HEAD)"
  TREE_OK=false
  if (cd "$REPO4" && git show teleport/test4-branch:committed.txt 2>/dev/null | diff -q - "$REPO4/committed.txt" >/dev/null) \
    && (cd "$REPO4" && git ls-tree -r teleport/test4-branch --name-only | grep -qx untracked.txt) \
    && (cd "$REPO4" && ! git ls-tree -r teleport/test4-branch --name-only | grep -qx deleted.txt); then
    TREE_OK=true
  fi

  PUSHED_OK=false
  if git ls-remote "$BARE4" | grep -q "refs/heads/teleport/test4-branch"; then
    PUSHED_OK=true
  fi

  UNPACK4="$SANDBOX/unpack4"
  "$UNPACK" "$REPO4/teleport-test4-branch.zip" --dir "$UNPACK4" >"$SANDBOX/t4-unpack.out" 2>&1
  BUNDLE4="$UNPACK4/teleport-test4-branch"
  RESUME_OK=false
  if [[ -f "$BUNDLE4/RESUME.md" ]] \
    && grep -q "teleport/test4-branch" "$BUNDLE4/RESUME.md" \
    && ! grep -q "git apply" "$BUNDLE4/RESUME.md" \
    && [[ ! -e "$BUNDLE4/uncommitted.patch" ]]; then
    RESUME_OK=true
  fi

  if [[ "$STATUS_BEFORE" == "$STATUS_AFTER" && "$HEAD_BEFORE" == "$HEAD_AFTER" && "$TREE_OK" == true && "$PUSHED_OK" == true && "$RESUME_OK" == true ]]; then
    pass "4. --branch: tree has change, worktree unchanged, pushed to origin, RESUME.md has branch path only"
  else
    fail "4. --branch: tree has change, worktree unchanged, pushed to origin, RESUME.md has branch path only"
  fi
else
  fail "4. pack --branch failed (see $SANDBOX/t4.out)"
fi

# ---------------------------------------------------------------------------
# 5. branch transport restores from a second clone of the remote
# ---------------------------------------------------------------------------
CLONE4B="$SANDBOX/clone4b"
if git clone -q "$BARE4" "$CLONE4B" >"$SANDBOX/t5-clone.out" 2>&1 \
  && (cd "$CLONE4B" && git fetch -q origin teleport/test4-branch && git checkout -q teleport/test4-branch) >"$SANDBOX/t5-checkout.out" 2>&1 \
  && diff -q "$CLONE4B/committed.txt" "$REPO4/committed.txt" >/dev/null \
  && diff -q "$CLONE4B/untracked.txt" "$REPO4/untracked.txt" >/dev/null \
  && [[ ! -e "$CLONE4B/deleted.txt" ]]; then
  pass "5. branch transport restores clean from a second clone of the remote"
else
  fail "5. branch transport restores clean from a second clone of the remote (see $SANDBOX/t5-checkout.out)"
fi

# ---------------------------------------------------------------------------
# 6. no-branch (patch transport) RESUME.md contains the patch-apply path
# ---------------------------------------------------------------------------
if [[ -f "$SANDBOX/unpack1/teleport-test1-patch/RESUME.md" ]] \
  && grep -q "git apply" "$SANDBOX/unpack1/teleport-test1-patch/RESUME.md" \
  && grep -q "uncommitted.patch" "$SANDBOX/unpack1/teleport-test1-patch/RESUME.md"; then
  pass "6. patch-transport RESUME.md contains the patch-apply path"
else
  fail "6. patch-transport RESUME.md contains the patch-apply path"
fi

# ---------------------------------------------------------------------------
# 7. pack from a repo subdir produces the same bundle content
# ---------------------------------------------------------------------------
REPO7="$SANDBOX/repo7"
make_fixture_repo "$REPO7"
write_md_files "$REPO7"

ROOT_OK=false
SUB_OK=false
(cd "$REPO7" && "$PACK" --history "$FAKE_HISTORY" --name test7-root >"$SANDBOX/t7-root.out" 2>&1) && ROOT_OK=true
(cd "$REPO7/sub" && "$PACK" --history "$FAKE_HISTORY" --name test7-sub >"$SANDBOX/t7-sub.out" 2>&1) && SUB_OK=true

if [[ "$ROOT_OK" == true && "$SUB_OK" == true ]]; then
  UNPACK7A="$SANDBOX/unpack7a-root"
  UNPACK7B="$SANDBOX/unpack7b-root"
  "$UNPACK" "$REPO7/teleport-test7-root.zip" --dir "$UNPACK7A" >/dev/null 2>&1
  "$UNPACK" "$REPO7/teleport-test7-sub.zip" --dir "$UNPACK7B" >/dev/null 2>&1
  BA="$UNPACK7A/teleport-test7-root"
  BB="$UNPACK7B/teleport-test7-sub"
  TREE_A="$(jq -r '.git.tree_sha' "$BA/MANIFEST.json")"
  TREE_B="$(jq -r '.git.tree_sha' "$BB/MANIFEST.json")"
  if diff -q "$BA/uncommitted.patch" "$BB/uncommitted.patch" >/dev/null 2>&1 && [[ "$TREE_A" == "$TREE_B" ]]; then
    pass "7. pack from repo root and from a subdir produce the same content"
  else
    fail "7. pack from repo root and from a subdir produce the same content"
  fi
else
  fail "7. pack from root or subdir failed"
fi

# ---------------------------------------------------------------------------
# 8. pack fails loudly during an in-progress merge
# ---------------------------------------------------------------------------
REPO8M="$SANDBOX/repo8-merge"
mkdir -p "$REPO8M"
(
  cd "$REPO8M"
  git init -q -b main
  git config user.email "test@example.com"
  git config user.name "test"
  echo "base" > conflict.txt
  git add conflict.txt
  git commit -q -m base
  git checkout -q -b feature
  echo "feature" > conflict.txt
  git commit -q -am "feature change"
  git checkout -q main
  echo "main" > conflict.txt
  git commit -q -am "main change"
  git merge feature >/dev/null 2>&1 || true
)
write_md_files "$REPO8M"

if (cd "$REPO8M" && "$PACK" --history "$FAKE_HISTORY" --name test8-merge >"$SANDBOX/t8m.out" 2>&1); then
  fail "8. pack should fail during an in-progress merge"
else
  if grep -qi "merge\|rebase\|cherry-pick" "$SANDBOX/t8m.out"; then
    pass "8. pack fails loudly during an in-progress merge"
  else
    fail "8. pack failed but without a clear merge/rebase message"
  fi
fi

# ---------------------------------------------------------------------------
# 9. unpack rejects an otherwise-valid bundle with a path-traversal member,
#    and one with a symlink member, with the specific rejection message
#    (not just any nonzero exit)
# ---------------------------------------------------------------------------
VALID_ZIP="$REPO1/teleport-test1-patch.zip"
if [[ -f "$VALID_ZIP" ]]; then
  EVIL_PY="$SANDBOX/make_evil.py"
  cat > "$EVIL_PY" <<'PYEOF'
import sys, zipfile

kind, src, out = sys.argv[1], sys.argv[2], sys.argv[3]

with zipfile.ZipFile(src) as zin, zipfile.ZipFile(out, "w") as zout:
    for item in zin.infolist():
        zout.writestr(item, zin.read(item.filename))
    if kind == "traversal":
        zout.writestr("../evil.txt", "escaped")
    elif kind == "symlink":
        info = zipfile.ZipInfo("evil-link")
        info.external_attr = 0o120777 << 16
        zout.writestr(info, "target.txt")
PYEOF

  EVIL9A="$SANDBOX/evil9-traversal.zip"
  EVIL9B="$SANDBOX/evil9-symlink.zip"
  python3 "$EVIL_PY" traversal "$VALID_ZIP" "$EVIL9A"
  python3 "$EVIL_PY" symlink "$VALID_ZIP" "$EVIL9B"

  T9_OK=true

  if "$UNPACK" "$EVIL9A" --dir "$SANDBOX/unpack9a" >"$SANDBOX/t9a.out" 2>&1; then
    T9_OK=false
  elif ! grep -q "unsafe path in zip member" "$SANDBOX/t9a.out"; then
    T9_OK=false
  fi

  if "$UNPACK" "$EVIL9B" --dir "$SANDBOX/unpack9b" >"$SANDBOX/t9b.out" 2>&1; then
    T9_OK=false
  elif ! grep -q "symlink member rejected" "$SANDBOX/t9b.out"; then
    T9_OK=false
  fi

  # rejection happens before extraction: nothing should have escaped unpack9a/
  if [[ -e "$SANDBOX/evil.txt" ]]; then
    T9_OK=false
  fi

  if [[ "$T9_OK" == true ]]; then
    pass "9. unpack rejects traversal and symlink members with the specific message"
  else
    fail "9. unpack rejects traversal and symlink members with the specific message (see $SANDBOX/t9a.out, $SANDBOX/t9b.out)"
  fi
else
  fail "9. no valid bundle from assertion 1 to build the evil zips from"
fi

# ---------------------------------------------------------------------------
# 10. pack works in an unborn-HEAD repo
# ---------------------------------------------------------------------------
REPO10U="$SANDBOX/repo10-unborn"
mkdir -p "$REPO10U"
(
  cd "$REPO10U"
  git init -q -b main
  git config user.email "test@example.com"
  git config user.name "test"
  echo "untracked only" > untracked.txt
)
write_md_files "$REPO10U"

if (cd "$REPO10U" && "$PACK" --history "$FAKE_HISTORY" --name test10-unborn >"$SANDBOX/t10u.out" 2>&1); then
  UNPACK10="$SANDBOX/unpack10"
  "$UNPACK" "$REPO10U/teleport-test10-unborn.zip" --dir "$UNPACK10" >/dev/null 2>&1
  B10="$UNPACK10/teleport-test10-unborn"
  HEAD10="$(jq -r '.git.head_sha' "$B10/MANIFEST.json")"
  if [[ -f "$B10/uncommitted.patch" ]] && grep -q "untracked.txt" "$B10/uncommitted.patch" && [[ "$HEAD10" == "null" ]]; then
    pass "10. pack works in an unborn-HEAD repo"
  else
    fail "10. pack works in an unborn-HEAD repo (unexpected bundle content)"
  fi
else
  fail "10. pack failed in an unborn-HEAD repo (see $SANDBOX/t10u.out)"
fi

# ---------------------------------------------------------------------------
# 11. secret scan flags a planted AKIA string in an untracked file
# ---------------------------------------------------------------------------
REPO11="$SANDBOX/repo11"
make_fixture_repo "$REPO11"
write_md_files "$REPO11"
echo "AKIAABCDEFGHIJKLMNOP" > "$REPO11/secret.txt"

(cd "$REPO11" && "$PACK" --history "$FAKE_HISTORY" --name test11-secret >"$SANDBOX/t11.out" 2>&1)
if [[ -f "$REPO11/teleport-test11-secret.zip" ]] && grep -qi "possible secret pattern" "$SANDBOX/t11.out"; then
  pass "11. secret scan flags a planted AKIA string, does not block"
else
  fail "11. secret scan flags a planted AKIA string (see $SANDBOX/t11.out)"
fi

# ---------------------------------------------------------------------------
# 12. two ambiguous codex history candidates -> pack fails, asks for --history
# ---------------------------------------------------------------------------
REPO12="$SANDBOX/repo12"
make_fixture_repo "$REPO12"
write_md_files "$REPO12"
REPO12_ABS="$(cd "$REPO12" && pwd)"

FAKE_HOME="$SANDBOX/fakehome"
CODEX_DIR="$FAKE_HOME/.codex/sessions/2026/08/28"
mkdir -p "$CODEX_DIR"
printf '{"payload":{"cwd":"%s"}}\n' "$REPO12_ABS" > "$CODEX_DIR/rollout-1.jsonl"
printf '{"payload":{"cwd":"%s"}}\n' "$REPO12_ABS" > "$CODEX_DIR/rollout-2.jsonl"

if (cd "$REPO12" && env -u CLAUDE_CODE_SESSION_ID HOME="$FAKE_HOME" "$PACK" --name test12-ambiguous >"$SANDBOX/t12.out" 2>&1); then
  fail "12. pack should fail on ambiguous codex history candidates"
else
  if grep -q -- "--history" "$SANDBOX/t12.out"; then
    pass "12. ambiguous codex candidates: pack fails and asks for --history"
  else
    fail "12. pack failed but did not ask for --history (see $SANDBOX/t12.out)"
  fi
fi

# ---------------------------------------------------------------------------
echo "---"
if [[ "$FAILS" -eq 0 ]]; then
  echo "all assertions passed"
  exit 0
else
  echo "$FAILS assertion(s) failed"
  exit 1
fi
