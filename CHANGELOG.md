# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Every change opens a new version, so there is no `Unreleased` section — these
scripts are always consumed from `main`, which means a change that lands is a
change that has shipped. Each version also records the commit message that
carried it.

Versions below 2.0.0 were reconstructed from git history after the fact; the
repository carries no tags yet.

## [2.2.0] - 2026-07-28

### Commit message

<details><summary>For the GitHub Desktop Summary and Description fields</summary>

```
Add a guided flow for creating a session

Registering a session meant knowing the add syntax and typing a path
from memory. Pressing n in the session table now walks through it: name,
working directory, autostart, remote control, and whether to start it
straight away. The same flow is available as "claude.sh new".

The directory question offers candidates rather than a blank prompt --
the current directory, the work directory and what is under it, the
parents of sessions already registered, and home -- with "somewhere
else" to type a path. A relative path resolves against the current
directory and a directory that does not exist yet is created.

Names are validated as they are typed: an illegal character or a name
already in the registry re-prompts instead of failing at the end. With
no terminal, or under ASSUME_YES, it points at claude.sh add rather than
silently taking defaults for questions nobody answered.
```

</details>

### Added

- `n` in the session table, and `claude.sh new`, walk through creating a
  session: name, working directory, autostart, remote control, and whether to
  start it now.
- The working directory question offers candidates — the current directory, the
  work directory and its subdirectories, the parents of registered sessions, and
  home — with "somewhere else" to type a path. Relative paths resolve against
  the current directory, and a directory that does not exist yet is created.
- Names are checked as they are entered, so an illegal character or a duplicate
  re-prompts rather than failing after every other question has been answered.

## [2.1.0] - 2026-07-28

### Commit message

<details><summary>For the GitHub Desktop Summary and Description fields</summary>

```
Support multiple sessions, with an optional Remote Control flag

claude.sh managed exactly one session. It now manages any number, each
with its own working directory, listed one per line in
~/.config/claude-sessions.conf:

    claude    /home/matt/work        autostart
    api       /home/matt/work/api    autostart remote
    scratch   /tmp/scratch           noautostart

Only autostart sessions are brought back by the @reboot entry, so a
scratch session can stay registered without returning after a reboot.
Flags are order-independent. Running claude.sh with no arguments now
prints a table of sessions and their state; pick a number to Enter,
Restart, Stop or Start one, or use s / r / x to act on all of them.

A session marked remote launches as "claude --remote-control <name>", so
it can be driven from claude.ai/code and the Claude mobile app while
still running on this box against this filesystem. Toggle it with
"claude.sh remote <name> on|off". Remote Control needs a claude.ai login
and refuses API keys, so the script warns when ANTHROPIC_API_KEY or
ANTHROPIC_BASE_URL is set at the moment you turn the flag on rather than
letting the session fail later.

Upgrading is automatic: an existing ~/.config/claude-session.env is
folded into the registry on first run and the session carries over.
```

</details>

### Added

- Any number of sessions, each with its own working directory, registered one
  per line in `~/.config/claude-sessions.conf`. `add`, `rm` and `list` manage
  them; `start`, `stop` and `restart` take any number of names, or act on every
  autostart session when given none.
- A `remote` flag per session. It launches Claude Code with
  [Remote Control](https://code.claude.com/docs/en/remote-control), so the
  session can be driven from claude.ai/code and the Claude mobile app while
  still running on the box. Toggle with `claude.sh remote <name> on|off`, or
  from the session menu. Turning it on checks for `ANTHROPIC_API_KEY` and
  `ANTHROPIC_BASE_URL`, which Remote Control rejects, and says so immediately.
- A `noautostart` flag, so a session can stay registered without being brought
  back by the `@reboot` entry.
- Running `claude.sh` with no arguments prints a table of every session with its
  state, flags and working directory, then lets you act on one or on all.
  Sessions running under `screen` that are not in the registry are listed too,
  rather than silently ignored.

### Changed

- **Breaking:** `WORK_DIR` and `SESSION_NAME` no longer configure the script;
  sessions come from the registry instead. An existing
  `~/.config/claude-session.env` is migrated into it automatically on first run,
  so an upgrade keeps working without intervention.
- **Breaking:** `enter` takes a session name. It may still be omitted when
  exactly one session is running.
- The boot script starts every autostart session, and accepts a name to start
  just one.

## [2.0.1] - 2026-07-27

### Commit message

<details><summary>For the GitHub Desktop Summary and Description fields</summary>

```
Create home directories as the user, not as root

Running claude.sh as root left ~/.local owned by root: mkdir -p on
~/.local/bin creates the parent too, and only the leaf was handed back.
The Claude Code installer runs as the target user, so it then failed
with EACCES creating ~/.local/share and claude was never installed.

Directories under the target user's home are now created as that user,
and ~/.config, ~/.local and the work directory are handed over on every
install, which repairs boxes an earlier version already broke.

The boot stub records a checksum of what was written. An untouched stub
is upgraded in place on the next run rather than producing a .new file
every time the packaged version changes; a stub you have edited is still
never overwritten.

2.0.0 claimed to remove archive/.probe but the deletion was not part of
the commit. Removing it here instead.
```

</details>

### Fixed

- Running `claude.sh` as root no longer leaves `~/.local` owned by root, which
  made the Claude Code installer fail with `EACCES: permission denied, mkdir
  '~/.local/share'`. `mkdir -p ~/.local/bin` creates `~/.local` too, and only
  the leaf was being handed back to the user. Directories in the target user's
  home are now created as that user, and `~/.config`, `~/.local` and the work
  directory are handed over on every install — so a box an earlier version
  already broke is repaired by re-running.
- An unmodified `claude-session-boot.sh` is upgraded in place instead of
  producing a `.new` file every time the packaged stub changes. A checksum of
  the last written stub is kept beside it; a stub you have edited yourself is
  still never overwritten.

### Removed

- `archive/.probe`, a stray empty file committed by accident in 1.0.0. The
  2.0.0 entry claimed this, but the deletion was not actually part of that
  commit.

## [2.0.0] - 2026-07-27

### Commit message

<details><summary>For the GitHub Desktop Summary and Description fields</summary>

```
Split curl.sh into a package picker and a separate claude.sh

curl.sh is now a catalog of tools rather than a fixed provisioning run.
With no arguments it shows a checklist of everything it can install
alongside what is already present and at which version; numbers toggle
entries, 'a' selects all, 'm' selects only what is missing, and Enter
installs the selection in catalog order so the system update runs first
and git lands before anything that depends on it. Named entries work
non-interactively too: install git docker, install all, install missing,
or a bare name as shorthand. Every install stayed idempotent.

Claude Code and its boot session move out to claude.sh, which installs
its own prerequisites (git, screen, cron, Claude Code) and so works
standalone on a bare box. It keeps the Enter / Restart / Stop menu, the
editable claude-session-boot.sh stub, the @reboot crontab entry and the
WORK_DIR / SESSION_NAME / CLAUDE_CMD configuration.

Selecting "claude" in curl.sh delegates to claude.sh rather than
duplicating the logic, preferring a sibling copy when run from a clone
and fetching it from the repo otherwise.

The crontab marker changed to "managed by claude.sh", so claude.sh also
recognises the old "managed by curl.sh" marker and replaces that entry
instead of leaving a duplicate @reboot line behind.

Add CLAUDE.md, covering the changelog requirement, the shell and testing
conventions these scripts already follow, and commit conventions. Add
CHANGELOG.md in Keep a Changelog form, backfilled from git history; the
version numbers there were assigned retroactively, as the repository
carries no tags yet.

Every change opens a new version rather than accumulating under an
Unreleased heading: these scripts are always consumed from main, so a
change that lands is a change that has shipped. Each version records the
commit message that carried it, directly under its heading, since GitHub
Desktop cannot read a commit template.

Running as root with SUDO_USER set was broken: $SUDO is empty once you
are root, so "$SUDO -u ..." left the shell trying to run -u as a command
and Claude Code never installed. Fixing that exposed four more, all in
the same seam between "who is running this" and "who is this for":
screen sockets are per-user so root could not see the session it had
just started; SUDO_USER was trusted even in a non-root shell, pointing
at the wrong home; a root run left the boot log root-owned so the cron
job could never append to it; and sudo -v prompts for a password even
under NOPASSWD, failing with no tty. Session names are now matched
literally rather than as a regex, since a name containing . or + could
fail to match itself and start a duplicate session on every boot.

Also drop archive/.probe, a stray empty file committed by accident.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01PN1YYcEXvDEpYVfLf1ugK5
```

</details>

### Added

- `claude.sh`, a standalone script for Claude Code and its boot session. It
  installs its own prerequisites, so it works alone on a bare box.
- `curl.sh` now takes named entries without prompting: `install git docker`,
  `install all`, `install missing`, or a bare name as shorthand.
- `curl.sh list` shows the catalog alongside what is already installed and at
  which version.
- `CLAUDE.md` and this changelog.

### Changed

- **Breaking:** `curl.sh` no longer provisions a fixed set of packages. It now
  shows a checklist of what it can install and installs only what you select.
  Selections are applied in catalog order, so the system update runs first and
  `git` lands before anything that depends on it.
- **Breaking:** Claude Code setup moved out of `curl.sh`. Selecting `claude` in
  the checklist delegates to `claude.sh`, preferring a copy sitting next to
  `curl.sh` when run from a clone and fetching it from the repository
  otherwise.
- **Breaking:** the session commands (`start`, `enter`, `restart`, `stop`,
  `status`, `uninstall`) moved from `curl.sh` to `claude.sh`.
- The `@reboot` crontab entry is now marked `managed by claude.sh`.

### Fixed

- Upgrading from 1.0.0 no longer leaves two `@reboot` entries behind.
  `claude.sh` recognises the old `managed by curl.sh` marker and replaces that
  entry instead of adding a second one. Unrelated crontab lines are untouched.
- Catalog columns stay aligned when colour is enabled.
- Running either script as root — via `sudo -i`, `sudo su` or similar, with
  `SUDO_USER` set — no longer fails with `-u: command not found`. `$SUDO` is
  empty when already root, so `$SUDO -u ...` left the shell trying to run `-u`
  as a command. Claude Code silently failed to install as a result.
- `claude.sh` now finds a session owned by another user. screen sockets live in
  a per-user directory, so a session started for `$SUDO_USER` was invisible to
  root: `start` reported that it had not come up, `status` said `no`, and the
  Enter / Restart / Stop menu never appeared.
- `SUDO_USER` is only trusted when actually running as root. In a non-root
  shell a leftover value pointed the config, boot script and work directory at
  the wrong user's home.
- The boot log is created and handed to the target user before it is written,
  rather than being left root-owned by a run made as root — which then blocked
  every later run, including the `@reboot` cron job, from appending to it.
- Sudo is probed with `sudo -n true` before falling back to `sudo -v`, which
  prompts for a password even where `NOPASSWD` applies and fails outright with
  no tty.
- Session names are matched literally rather than as a regular expression. A
  `SESSION_NAME` containing `.`, `+` or `*` could fail to match its own
  session, which would start a duplicate on every boot.
- A wedged `claude --version` can no longer hang provisioning; version probes
  are wrapped in `timeout 10`.

## [1.0.0] - 2026-07-27

### Commit message

<details><summary>For the GitHub Desktop Summary and Description fields</summary>

```
Land the curl.sh rewrite; drop the stray bundle file

The previous commit carried this message but only added
curl-update.bundle, a transfer artifact that was never meant to be
committed. This commit removes it and lands the intended change.

Move the previous scripts (curl.sh, old_curl.sh, backup_test.sh,
01-custom-motd) into archive/ unchanged, and replace curl.sh with a
bootstrapper for headless Claude Code boxes.

The new script provisions Ubuntu idempotently: apt update/upgrade, then
git first, followed by screen, curl, cron, btop (htop fallback), Docker
Engine + Compose plugin from Docker's apt repo, Tailscale, and Claude
Code via the native installer. Every step checks before it acts, so
re-running only reports what is already in place.

It then writes ~/.config/claude-session.env, an editable
~/.local/bin/claude-session-boot.sh stub that launches Claude Code in a
detached screen session inside a configurable WORK_DIR, and a marked
@reboot crontab entry that runs the stub on every boot. The stub is
never overwritten once it exists; a .new file is written alongside it.

On a subsequent run, if the screen session is already up, the script
offers an Enter / Restart / Stop menu rather than reinstalling anything.
Settings resolve from the environment, then the config file, then
built-in defaults.

Note: `restart` now restarts the Claude Code session rather than the OS;
`reboot` restarts the machine.
```

</details>

### Added

- `curl.sh` rewritten as an idempotent provisioner: `apt` update and upgrade,
  then git first, followed by `screen`, `curl`, `cron`, `btop` (falling back to
  `htop` where unavailable), Docker Engine with the Compose plugin from
  Docker's own apt repository, Tailscale, and Claude Code via the native
  installer.
- `~/.config/claude-session.env` for `WORK_DIR`, `SESSION_NAME` and
  `CLAUDE_CMD`. The environment wins, then this file, then built-in defaults.
- `~/.local/bin/claude-session-boot.sh`, an editable stub that launches Claude
  Code in a detached `screen` session. It is written once and never overwritten
  afterwards; a `.new` file is written alongside instead.
- A `@reboot` crontab entry that runs the boot stub on every boot, logging to
  `~/.local/state/claude-session-boot.log`.
- An Enter / Restart / Stop menu shown when a session is already running,
  instead of reinstalling anything.
- `archive/`, holding the previous `curl.sh`, `old_curl.sh`, `backup_test.sh`
  and `01-custom-motd` unchanged.

### Changed

- **Breaking:** `restart` restarts the Claude Code session rather than the
  machine. `reboot` restarts the machine.
- **Breaking:** the old interactive menu (list containers, folder sizes, update,
  list ports) is gone from `curl.sh`; it remains in `archive/curl.sh`.

