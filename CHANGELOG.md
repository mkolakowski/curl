# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Versions below 2.0.0 were reconstructed from git history after the fact; the
repository carries no tags yet.

## [Unreleased]

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

### Removed

- `archive/.probe`, a stray empty file committed by accident in 1.0.0.

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

