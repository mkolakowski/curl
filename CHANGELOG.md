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

## [2.11.0] - 2026-07-30

### Commit message

<details><summary>For the GitHub Desktop Summary and Description fields</summary>

```
Build the session menu from the session's state

The per-session menu offered the same seven entries whatever the session
was doing, and three of them were dead at any moment. Worse, Enter sat
under the default keystroke: choosing a stopped session and pressing
Enter called enter_one, which calls die(), which exits the whole script
— so the single likeliest keystroke sequence dropped you back to the
shell instead of doing anything.

The entries are now built from the state. A stopped session offers
Start, Remote and Back; a running one Enter, Restart, Stop, Remote and
Back. The default is always the verb you came for, and the numbers only
ever name things that can actually happen.

Remote and Mode were two entries for one three-state setting, so going
from off to interactive took two visits. They are now one entry that
cycles off -> server -> interactive -> off, labelled with where it will
land rather than leaving you to work it out.

Two remaining ways to fall out of the menu are closed: start_one called
die() when the boot script was missing, which is both fatal and needless
when it can simply write the file, and Enter now rechecks that the
session is still running rather than trusting the menu it drew a moment
ago.
```

</details>

### Changed

- The per-session menu is built from the session's state. A stopped session
  offers Start, Remote and Back; a running one Enter, Restart, Stop, Remote and
  Back. Previously all seven entries showed regardless, three of them dead at
  any given moment.
- Remote and Mode are one entry that cycles off → server mode → interactive →
  off, labelled with where it will land. Reaching interactive from off used to
  take two separate choices.

### Fixed

- Choosing a stopped session and pressing Enter — the default — exited the whole
  script. Enter mapped to a code path that calls `die()`, so the likeliest
  keystroke on a table where everything is stopped dropped you back to the
  shell.
- A missing boot script no longer aborts the program; it is written, the same
  way a stale one is already replaced.
- Enter rechecks that the session is still running, rather than trusting the
  state the menu was drawn with.

## [2.10.0] - 2026-07-30

### Commit message

<details><summary>For the GitHub Desktop Summary and Description fields</summary>

```
Add a docker containers submenu: cloudflared, beszel-agent, dockge

Pressing d in the package checklist opens a second checklist of
container stacks, with the same toggle-by-number picker. Also reachable
as "curl.sh containers", or "curl.sh containers dockge" to skip the menu.

Each entry is written as a compose stack under /opt/stacks/<name>, which
is the directory Dockge itself manages -- so anything installed this way
turns up in Dockge ready to edit, start and stop, rather than being an
opaque docker run nobody can later reconstruct. CURL_SH_STACKS_DIR moves
them. Docker is installed first if it is missing.

cloudflared needs a tunnel token and beszel-agent needs a hub URL, token
and key. Those are asked for and written to a chmod 600 .env beside the
compose file, so no secret ends up in the compose file or in shell
history. An empty answer is allowed: the stack is written with
REPLACE_ME, left stopped, and the script names the file to finish. A
.env already filled in is not asked about again.

Also fixes an infinite loop in both pickers: with ASSUME_YES set or no
terminal, ask() returns the default immediately, nothing is ever
selected, and the confirm branch looped forever. Both now say what to
name instead and exit.
```

</details>

### Added

- A **docker containers** submenu, reached with `d` from the package checklist
  or as `curl.sh containers`: `cloudflared`, `beszel-agent` and `dockge`, with
  the same toggle-by-number picker and a state column showing what is already
  running. `curl.sh containers <name>...` skips the menu.
- Each container is written as a compose stack under `/opt/stacks/<name>/`, the
  directory Dockge manages, so installs show up in Dockge ready to edit and
  control. `CURL_SH_STACKS_DIR` relocates them. Docker is installed first if
  missing.
- Stacks needing a secret prompt for it and write a `chmod 600` `.env` beside
  the compose file. Skipping leaves `REPLACE_ME` and the stack stopped, with the
  file named; a `.env` already complete is not asked about again.

### Fixed

- Both pickers looped forever when run with `ASSUME_YES=1` or without a
  terminal: `ask` returned the default immediately, so nothing was ever selected
  and the confirm branch repeated. They now explain what to name and exit.
- A failed `docker compose up -d` prints the reason instead of discarding it.

## [2.9.0] - 2026-07-30

### Commit message

<details><summary>For the GitHub Desktop Summary and Description fields</summary>

```
Add purplemux to the catalog, prerequisites included

purplemux is a web-native terminal multiplexer for Claude Code and
Codex, so it belongs next to the rest of this. It needs tmux and Node.js
20+, and Ubuntu ships an older nodejs than that, so the entry installs
both rather than failing on a box that has neither: apt for tmux, and
NodeSource for Node when what is present is older than 20. Node is left
alone when it already satisfies the minimum.

The installed version is read out of the package's package.json rather
than by running the binary, since purplemux is a server and an
unrecognised --version could start it instead of printing. The path
comes from "npm root -g" rather than an assumed prefix, because a user
with their own npm prefix puts global packages somewhere else.
```

</details>

### Added

- `purplemux` in the `curl.sh` catalog — a web terminal multiplexer for Claude
  Code. Selecting it installs its prerequisites in the same step: `tmux`, and
  Node.js 20+ from NodeSource when the box has something older. Node is left
  alone if it already meets the minimum. Once installed, run `purplemux` and
  open `http://localhost:8022`.

## [2.8.0] - 2026-07-29

### Commit message

<details><summary>For the GitHub Desktop Summary and Description fields</summary>

```
Start screen in the work directory, and keep each session's output

screen was started from wherever the script happened to be, with only
the window cding into the work directory. The distinction matters: the
session daemon's working directory is what a new window (Ctrl-a c)
inherits and what you land in if the command exits, so opening a second
window in a session dropped you somewhere unrelated. screen is now
launched from the work directory itself, and a directory it cannot enter
is reported and skipped rather than silently producing a dead session.

A session whose command exits immediately used to vanish without a
trace: the screen session was gone before anything could read it, so a
failure looked identical to a session that never started. Each window is
now recorded with screen's -Logfile, and a start that fails quotes the
last lines the session printed. For an unsigned-in box that turns "did
not come up" into "Remote Control requires a claude.ai subscription /
Run: claude auth login". doctor shows the same log for a session that
has exited, and the logging is skipped on screen older than 4.06, which
predates -Logfile.

Stub contract goes to 5, so existing boot scripts are replaced.
```

</details>

### Fixed

- `screen` is now started **from** the session's work directory, not merely told
  to `cd` inside the window. The session daemon's directory is what a new window
  inherits and where you land if the command exits, so a second window in a
  session previously opened somewhere unrelated.
- A work directory that cannot be entered is reported and the session skipped,
  instead of producing a session that dies immediately.

### Added

- Each session's output is captured to
  `~/.local/state/claude-sessions/<name>.log` using screen's `-Logfile`, so a
  session that exits straight away still leaves the reason behind. A failed
  start now quotes those lines — on a box that is not signed in, `'x' did not
  come up` becomes the actual `Remote Control requires a claude.ai subscription`
  message. `doctor` shows the same for a session that has exited. Skipped
  automatically on screen older than 4.06, which has no `-Logfile`.

## [2.7.0] - 2026-07-29

### Commit message

<details><summary>For the GitHub Desktop Summary and Description fields</summary>

```
Replace an incompatible boot script instead of starting the wrong session

Picking a session and choosing Start could start a completely different
one. The boot script gained multi-session support in 2.1.0, but
write_boot_script refuses to overwrite a stub it cannot prove is
unmodified, and any stub written before 2.1.0 predates the checksum it
compares against. So upgraded boxes kept the single-session stub, which
ignores the session name it is passed and starts whatever its own
~/.config/claude-session.env says. Asking for SimpleVTT started claude
in ~/work, and the only clue was the session name in the log.

The generated stub now declares the contract it implements
("stub-version: 4"). A stub on disk that is recognisably ours but
declares a different version is copied to a .bak file and replaced,
because keeping it means silently starting the wrong session, which is
worse than replacing a file. A stub that is not ours still produces a
.new file and is never touched. start_one repairs a stale stub before
trusting it, rather than relying on anyone having run install.

When a session fails to appear, any other session that is running is now
named in the warning -- that is the symptom this bug produced.
```

</details>

### Fixed

- **Starting a session could start a different one.** The multi-session boot
  script arrived in 2.1.0, but a stub written before then predates the checksum
  that guards overwriting, so upgraded boxes silently kept the single-session
  version — which ignores the session name it is given and starts whatever its
  own old config names. Asking for one session started another, in the wrong
  directory. The stub now declares its contract version; one of ours declaring
  a different version is backed up to `.bak` and replaced rather than used, and
  `start` repairs a stale stub before trusting it.
- A session that fails to come up now names any other session that is running,
  which is exactly what this bug looked like from the outside.

## [2.6.0] - 2026-07-29

### Commit message

<details><summary>For the GitHub Desktop Summary and Description fields</summary>

```
Add --verbose, and stop a wedged probe from hanging the script

Starting a remote session went silent for up to a minute. The cause was
remote_blockers: it opened six separate "sudo bash -lc" login shells to
read one environment variable each, then ran claude auth status, and
printed nothing until all of it finished. On a slow box that is
indistinguishable from a hang.

The environment is now read in a single login shell, every probe runs
under a hard timeout so nothing can wedge indefinitely, and the script
says what it is waiting for before it waits.

-v / --verbose (or CLAUDE_SH_VERBOSE=1) traces each step with a
timestamp, the command being run as the target user, its exit code and
how long it took, so a stall can be pinned to one call rather than
guessed at.

Also fixes the session menu reporting "remote control: off" for a
session the table showed as server. The remote flag became three-valued
in 2.4.0 -- no, server, interactive -- but manage_one still compared it
against the old "yes", so every session read as off and option 5 toggled
from the wrong starting point. The menu now shows the real mode and
gains a Mode entry to switch between server and interactive.
```

</details>

### Added

- `-v` / `--verbose` (or `CLAUDE_SH_VERBOSE=1`) traces each step with a
  timestamp, the command run as the target user, its exit code and elapsed
  time. The flag may appear anywhere in the arguments.
- The script now says what it is waiting for before checking Remote Control
  preconditions and before reading a session's screen, so neither step is a
  silent pause.
- The session menu gained **Mode**, to switch a session between server-mode and
  interactive Remote Control without turning it off first.

### Fixed

- The session menu reported `remote control: off` for a session the table
  showed as `server`. The flag became three-valued in 2.4.0 but the menu still
  compared it against the old `yes`, so every session read as off and the
  toggle started from the wrong state.
- Starting a remote session could sit silent for close to a minute. The
  environment probe opened six separate login shells one after another; it now
  uses one. Every probe also runs under a hard timeout, so a wedged
  `claude auth status` costs 25 seconds instead of hanging indefinitely.

## [2.5.0] - 2026-07-28

### Commit message

<details><summary>For the GitHub Desktop Summary and Description fields</summary>

```
Print the version on every run

Both scripts are curled straight off main, so the version on a given box
is whatever was there when it was last run, and there was no way to ask.
Each now carries a VERSION constant and prints "curl.sh 2.5.0" as its
first line, with "version" (also -V, --version) printing the bare number
alone for scripting.

CLAUDE.md now requires bumping VERSION in both scripts in the same
commit as the changelog entry, since a stale constant reports the wrong
thing about the box it is running on.
```

</details>

### Added

- Both scripts print their version as the first line of every run, and accept
  `version`, `-V` or `--version` to print the bare number on its own for
  scripting.

### Changed

- `CLAUDE.md` now requires `VERSION` in both scripts to be bumped in the same
  commit as the changelog entry, and to match the newest heading.

## [2.4.0] - 2026-07-28

### Commit message

<details><summary>For the GitHub Desktop Summary and Description fields</summary>

```
Start remote sessions in server mode, and report when they do not connect

A session flagged remote launched as "claude --remote-control <name>",
which is a normal interactive session that is additionally reachable
from claude.ai. Crucially it does not fail when Remote Control cannot
connect -- it carries on as an ordinary local session and shows a
notification that nobody sees from a detached screen. That is why a
remote session appeared to start yet never showed up at claude.ai/code.

remote now means server mode: "claude remote-control --name <name>".
That process exists to serve remote connections and exits when it cannot
establish one, so a failure is visible instead of silent. The previous
behaviour is still available as a separate flag value,
remote-interactive, for a session you also want to type into on the box.

Before starting a remote session the script now checks what Remote
Control actually requires -- a claude.ai login via "claude auth status",
and the absence of ANTHROPIC_API_KEY, CLAUDE_CODE_OAUTH_TOKEN,
ANTHROPIC_BASE_URL, CLAUDE_CODE_USE_BEDROCK and CLAUDE_CODE_USE_VERTEX
-- and names whatever is wrong. A few seconds after launch it dumps the
session's screen with "screen -X hardcopy" and either prints the session
URL or quotes the failure.

Adds "claude.sh doctor [name]", which reports the version, login state,
offending environment variables, what claude doctor says about
eligibility, and what each running remote session currently shows.
```

</details>

### Added

- `claude.sh doctor [name]`, which answers "why is my remote session not
  showing up": Claude Code version, whether you are signed in to claude.ai, any
  environment variable Remote Control rejects, `claude doctor`'s eligibility
  lines, and for each running remote session what is actually on its screen.
- A `remote-interactive` flag value for the previous behaviour — a normal
  session that is also reachable remotely, so you can type on the box as well.
- Preconditions are checked before a remote session starts, and the session's
  screen is read a few seconds after launch to confirm Remote Control really
  connected, printing the claude.ai/code URL when it did.

### Changed

- **Breaking:** the `remote` flag now starts server mode
  (`claude remote-control --name <name>`) rather than
  `claude --remote-control <name>`. Server mode exists to be driven from
  claude.ai or the mobile app and has no local prompt, but it fails loudly when
  Remote Control cannot connect instead of silently degrading. Sessions that
  want the old behaviour should use `remote-interactive`.
- `claude.sh remote <name>` takes `on`, `interactive` or `off`.

## [2.3.0] - 2026-07-28

### Commit message

<details><summary>For the GitHub Desktop Summary and Description fields</summary>

```
Clone a repo when creating a session; add the GitHub CLI to curl.sh

The directory question in "claude.sh new" gains a "clone a GitHub repo"
option: give it owner/name, an https or git@ URL, or a local path, say
where to put it, and the clone becomes the session's working directory.
It clones with gh when the GitHub CLI is installed and signed in, so
private repos work, and falls back to git otherwise, saying which it
used. A destination that is already a clone offers to be reused rather
than failing, and a non-empty directory that is not a clone is refused.

curl.sh gains a gh entry, installed from GitHub's own apt repository
next to git in the catalog, and reports whether gh is signed in.

Also fix a registry corruption: the work directory column was padded to
34 characters with no guaranteed separator, so a path of exactly that
length ran into the flags and left a line like
"/home/matt/origin/demo-repoautostart". Parsing that gave back a wrong
directory and silently dropped the flags. Every column now emits a
literal space after its padding.
```

</details>

### Added

- "Clone a GitHub repo" in the working-directory question of `claude.sh new`.
  Accepts `owner/name`, an `https://` or `git@` URL, or a local path, asks where
  to put it, and uses the clone as the session's working directory. Uses `gh`
  when it is installed and signed in so private repos work, falling back to
  `git` and saying so. Reuses a destination that is already a clone, and refuses
  a non-empty directory that is not one.
- `gh`, the GitHub CLI, in the `curl.sh` catalog, installed from GitHub's own
  apt repository. It sits next to `git` and reports whether it is signed in.

### Fixed

- A work directory of exactly 34 characters corrupted its registry line. The
  column was padded to 34 with no guaranteed separator, so the path ran into the
  flags — `/home/matt/origin/demo-repoautostart` — and parsing it back gave a
  wrong directory with the flags silently dropped. Every column now emits a
  literal space after its padding, so a long path widens the row instead.

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

