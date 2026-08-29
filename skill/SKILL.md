---
name: teleport
description: pack the current session into a portable bundle, or resume a session from one. use for /teleport, /teleport pack, /teleport from <zip>, /teleport to <host> [harness], "teleport this session", "resume from bundle", "move this session to another machine".
---

# teleport

teleport packs a coding-agent session into one zip file. it moves the session to another
machine or another harness (claude, cursor, codex, opencode). the bundle is harness-agnostic:
the real payload is three plain markdown files. raw session history rides along as a
best-effort attachment, not the primary record.

## mode: pack (`/teleport`, `/teleport pack`)

1. make `.teleport/` at the repo root. write three files there:
   - `SUMMARY.md` — the goal, what you did, what is still planned, and the direction. use
     evidence (commands run, numbers seen), not vibes.
   - `FILES.md` — every file you touched this session, and a short overview of the change in
     each one.
   - `LEARNINGS.md` — findings, gotchas you paid for, key numbers, decisions with their
     evidence, and stop conditions for the next agent.

   write each file as one linear pass a fresh agent can follow start to end. name real files
   with real paths. carry exact commands, ids, and numbers. state open questions plainly — do
   not write vague summaries.

2. review the three files and any `--context` files for secrets and phi before you pack. if
   the pack script prints a scan warning, or the patch is large, confirm with the user before
   you go on.

3. run `<skill dir>/scripts/teleport-pack.sh`. pass `--history <file>` when the script asks
   for it (cursor, opencode, or ambiguous detection). pass `--branch` or `--push` only when the
   user allows a git push. pass `--with-doctrine` when the user requests it to include
   user-level doctrine and skill files in the bundle.

### doctrine (`--with-doctrine`)

when `--with-doctrine` is passed, pack copies user-level configuration into `doctrine/` inside
the bundle so the destination environment matches the source. best-effort: skip missing paths,
never fail the pack because a doctrine file is absent.

- scan these locations (all harnesses):
  - `~/.claude/CLAUDE.md`, `~/.claude/settings.json`
  - `~/.cursor/rules/**`, `~/.cursor/skills/**`
  - `~/.codex/instructions.md`, `~/.codex/skills/**`
  - `~/.config/opencode/config.*`, `~/.config/opencode/skills/**`
  - `~/.config/goose/config.*`, `~/.config/goose/skills/**`
  - `~/.config/pi/config.*`, `~/.config/pi/skills/**`
  - project-level equivalents under the repo root (`.claude/`, `.cursor/`, etc.)
- preserve relative paths inside `doctrine/` (e.g. `doctrine/user/claude/CLAUDE.md`,
  `doctrine/project/.cursor/rules/foo.mdc`).
- record what was included in MANIFEST.json under `doctrine.files`.
- on unpack, print the doctrine manifest and ask the user before restoring any files.
  never overwrite existing doctrine files silently — offer to merge, skip, or replace per file.

4. give the user the zip path. send the file too, when the harness supports it.

## mode: from (`/teleport from <zip>`)

1. run `<skill dir>/scripts/teleport-unpack.sh <zip>`.
2. read `RESUME.md`, `SUMMARY.md`, `FILES.md`, and `LEARNINGS.md` in full.
3. follow the restore steps in `RESUME.md` exactly. ask the user before you run `git apply`.
4. when a premise fails — missing remote, sha not found, patch conflict — stop and ask the
   user. do not improvise a fix.
5. once restored, continue the work as the same session.

## mode: to (`/teleport to <host> [harness]`)

1. run the pack steps above.
2. detect the remote cwd best-effort before scp:
   - read `cwd` from MANIFEST.json in the just-packed bundle.
   - probe the host: `ssh <host> 'test -d <cwd> && echo <cwd>'`. if it exists, use it as the
     remote target dir for both scp and restore.
   - fallback: `ssh <host> 'basename <cwd>'` to find a matching dir name under `$HOME`, or
     default to `~/`. never guess silently — tell the user what was detected and let them
     override.
3. `scp` the zip to the detected remote dir: `scp teleport-<name>.zip <host>:<remote-dir>/`.
4. print the one command for the user to run on the host. all harnesses use the same command:
   `/teleport from <remote-dir>/teleport-<name>.zip`. `[harness]` only changes the wording of
   that printed line — it names which agent to run the command in.
5. offer to run the restore command directly over ssh:
   `ssh <host> 'cd <remote-dir> && <harness-cmd> /teleport from teleport-<name>.zip'`.
   ask the user before executing. if they decline, just print the command as above.
6. if the host has no teleport skill installed, the bundle still works: it carries
   `_teleport/teleport-unpack.sh` and `_teleport/SKILL.md` so the host can bootstrap from the
   zip alone.

## quality bar for the md files

- no vague summaries. name files with paths.
- carry exact commands, ids, and numbers, not paraphrases.
- state open questions explicitly, so the next agent does not have to guess.

## privacy

never pack live patient data or phi. on a machine with a data-residency boundary, the boundary
wins over packing — refuse the pack and say why.
