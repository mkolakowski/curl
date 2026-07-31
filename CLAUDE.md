# CLAUDE.md

Guidance for Claude Code working in this repository.

## What this is

One standalone bash script, `curl.sh`, run straight off the web with nothing
installed first. It covers three things, each with its own submenu off the home
menu and its own branch of the CLI:

- **installers** — a checklist of packages (`curl.sh install docker`)
- **containers** — docker compose stacks under `/opt/stacks`
  (`curl.sh containers start dockge`)
- **claude sessions** — Claude Code running unattended in `tmux`, supervised by
  a templated systemd unit (`curl.sh session add site ~/GitHub/site`)

The session half was a second script, `claude.sh`, until 4.1.0. That file is now
a compatibility shim that re-execs `curl.sh session "$@"`, so the old URL keeps
working; it is a dozen lines and should stay that way. `archive/` holds
superseded scripts and is frozen — never edit anything under it.

## Keep the changelog

Every change a user of these scripts would notice gets an entry in
`CHANGELOG.md`, in the same commit that makes the change. This is not a
follow-up task.

- The format is [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
  project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
- **Every change opens a new version.** There is no `[Unreleased]` section and
  nothing accumulates: add a `## [X.Y.Z] - YYYY-MM-DD` heading at the top of the
  list, above the previous version, and put the entries under it. These scripts
  are always consumed from `main`, so a change that is merged is a change that
  is shipped — there is no window in which it is pending.
- Bump against the version directly below, judged on what a user of the scripts
  sees: breaking → major, a new command or catalog entry → minor, a fix or a
  docs change → patch. Breaking means an existing command now does something
  different, is gone, or is spelled differently.
- Entries go in an `### Added` / `### Changed` / `### Deprecated` /
  `### Removed` / `### Fixed` / `### Security` subsection.
- Write for someone running the scripts, not for someone reading the diff.
  "`curl.sh` no longer installs Docker unless you select it" beats "refactored
  `install_docker`".
- Prefix anything that changes existing behaviour with **Breaking:**.
- **Bump `VERSION` in `curl.sh` in the same commit.** It carries a
  `readonly VERSION=` near the top and prints it on every run, so a stale
  constant tells the user the wrong thing about the box they are on. It must
  equal the newest heading in `CHANGELOG.md`. The `claude.sh` shim carries no
  version of its own — it forwards to `curl.sh`, which prints one.
- Tagging is optional. If you do tag, the tag is `vX.Y.Z` and matches the
  heading exactly.
- Purely internal changes with no user-visible effect need no entry, and so no
  version bump. When unsure, add one.

### Record the commit message with the entry

Commits here are usually made from GitHub Desktop, which has a **Summary** field
and a **Description** field and cannot read a commit template. So every version
carries the message that shipped it, in a `### Commit message` block sitting
**directly under the version heading** — above `### Added` and the rest, not at
the bottom, since it is the part most often needed:

````markdown
### Commit message

<details><summary>For the GitHub Desktop Summary and Description fields</summary>

```
Imperative summary line, under ~72 characters

Wrapped prose explaining why, which is the Description field. The first
line above is the Summary field; everything after the blank line is the
Description.
```

</details>
````

Keep it paste-ready — no placeholders, no "TODO", correct at all times. It is
the actual commit message, so it follows the commit conventions below, and it is
the same text written to `.git/CLAUDE_COMMIT_MSG` for the hook.

Update the block whenever the entries below it change. One version means one
commit, so there is exactly one block per version — if a change turns out to
need two commits, it needs two version headings.

## Shell conventions

- Target bash on Ubuntu. The generated `claude-session-run.sh` and any git hooks
  are POSIX `sh` — test them with `sh -n` and `shellcheck -s sh`, not bash.
- `set -uo pipefail` — deliberately not `-e`. These scripts report failures per
  step and carry on rather than dying halfway through a provisioning run.
- Both scripts must stay runnable as `bash <(curl -Ss .../script.sh)`. Read
  interactive input through `ask()`, which uses `/dev/tty`; never assume stdin
  is the terminal.
- Every install step is idempotent: check first, print `skip` and return 0 when
  there is nothing to do.
- Honour `NO_COLOR`. Pad plain strings *before* wrapping them in colour escapes,
  or columns drift when colour is on.
- Never assume root. Use `$SUDO`, and `as_user` / `own` for anything landing in
  the invoking user's home directory.
- Anything written into `$HOME` that the user may edit — the boot stub — is
  written once and never overwritten. Write a `.new` file alongside instead.

## Testing

Do not hand back shell changes you have only read.

- `bash -n` and `shellcheck -S style` must be clean, both for the scripts and
  for any script they generate.
- Exercise the change. Interactive menus get driven over a pty, session handling
  gets a real `tmux` session, generated systemd units get `systemd-analyze
  verify`, and anything that edits a crontab gets tested against a crontab that
  already contains unrelated entries.
- Check tmux target syntax by running it, not by reading it. `=name` is a
  *session* target: `has-session` and `kill-session` take it, but `capture-pane`
  and `pipe-pane` want a *pane* and fail with "can't find pane" — silently, once
  stderr is discarded. Those need `=name:`.
- Test the upgrade path, not just the fresh install. Someone already has the
  previous version's files, cron entries and config on a box.

## Commits

- **Commit each change as soon as it is finished, and push it.** Do not carry
  on to the next piece of work with the last one uncommitted. One version is one
  commit, so letting several versions pile up in the working tree makes that
  impossible to honour after the fact: the edits are cumulative in the same
  files and the intermediate states cannot be reconstructed faithfully. Finish,
  commit, push, then start the next thing.
- Summary line in the imperative, under ~72 characters, no trailing period.
- Body is wrapped prose explaining *why*, not a restatement of the diff. Call
  out bugs found and fixed along the way.
- One logical change per commit, with its `CHANGELOG.md` entry included.
- `.git/hooks/prepare-commit-msg` uses `.git/CLAUDE_COMMIT_MSG` as the message
  for the next commit and then deletes it. When the commit will be made from a
  GUI client, write the message there rather than asking for it to be pasted.
