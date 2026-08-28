# teleport

teleport packs a coding-agent session into one zip file, so you can resume it on another
machine or another harness. the payload is harness-agnostic: three plain markdown files carry
the meaning, and raw session history rides along as a best-effort attachment.

## install

clone, then install:

```
git clone https://github.com/sisig-ai/teleport.git
cd teleport
```

user-level, all detected harnesses (claude, cursor, codex, opencode):

```
./install.sh
```

one harness only:

```
./install.sh claude
```

project-level (claude and cursor only):

```
./install.sh --project /path/to/repo
```

## modes

### pack

```
/teleport
```

the agent writes `SUMMARY.md`, `FILES.md`, `LEARNINGS.md` to `.teleport/`, then runs
`teleport-pack.sh` to build `teleport-<name>.zip` in the repo root.

pack script flags:

| flag | effect |
|------|--------|
| `--name a-b` | pick the bundle name instead of a random `word-word` |
| `--history FILE` | attach a session history file (repeatable; required for cursor/opencode) |
| `--context FILE` | attach an extra handoff file (repeatable) |
| `--branch` / `--push` | commit the uncommitted work to branch `teleport/<name>` and push it to `origin` (both flags do the same; needs a remote) |
| `--max-mb N` | raise the size preflight cap (default 200 mb of changed + untracked files) |

without `--branch`, uncommitted work travels as `uncommitted.patch` inside the zip.

### from

```
/teleport from teleport-rainbow-unicorn.zip
```

extracts the bundle, reads `RESUME.md` and the three md files, and resumes the session.
the agent follows the restore steps in `RESUME.md` (branch checkout or patch apply) and asks
before it changes the working tree.

manual unpack, with or without the skill installed:

```
skill/scripts/teleport-unpack.sh teleport-rainbow-unicorn.zip
```

(a bundle also carries the unpack script inside `_teleport/`.)

### to

```
/teleport to coder@dev-workstation codex
```

packs, then `scp`s the zip to the host, then prints the command to run there.

## bundle layout

```
teleport-<name>.zip
└── teleport-<name>/
    ├── MANIFEST.json        # name, created_at, source, git state, transport, history mode
    ├── SUMMARY.md           # goal, what was done, what is planned, direction
    ├── FILES.md             # files touched this session + change overview
    ├── LEARNINGS.md         # findings, gotchas, key numbers, decisions
    ├── RESUME.md            # boot instructions for the successor agent
    ├── uncommitted.patch    # diff vs head, binary, omitted when the tree is clean
    ├── history/             # raw session history, best effort
    ├── context/             # extra handoff files
    └── _teleport/           # unpack.sh + SKILL.md, for a host with no teleport installed
```

## harness support

| harness  | status                                            |
|----------|----------------------------------------------------|
| claude   | verified: history auto-detect, skill install both work |
| cursor   | skills dir exists; skill registration unverified |
| codex    | skills dir exists; skill registration unverified |
| opencode | unverified; no auto-detect for its sqlite history |

a bundle works even on a harness with no teleport install: it carries `_teleport/` with the
unpack script and `SKILL.md`, and `RESUME.md` gives plain restore steps.

## limits

- submodule content is not packed when the submodule is dirty. the manifest flags it.
- cursor and opencode session history is sqlite. teleport does not auto-detect it and does not
  scan it for secrets — pass `--history <file>` and review it by hand.
- no history format conversion between harnesses. `history/` is a raw, best-effort attachment.

## test

```
bash test/smoke.sh
```

runs 12 assertions against a fixture repo in a temp sandbox: patch apply with deletion,
missing and empty learnings file, `--branch` transport with push and second-clone restore,
patch transport, subdir invocation, in-progress merge, zip-path-traversal and symlink
rejection with exact messages, unborn head, secret-scan flagging, and ambiguous codex
history detection.
