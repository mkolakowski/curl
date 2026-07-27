# curl

Two scripts for setting up an Ubuntu box, both meant to be run straight off the
web with nothing installed first.

[`curl.sh`](curl.sh) is a checklist of tools — tick what you want, it installs
them. [`claude.sh`](claude.sh) sets up Claude Code to run headlessly in a
detached `screen` session that comes back by itself after a reboot.

They're independent. `curl.sh` can hand off to `claude.sh` if you tick the
`claude` entry, but neither needs the other to work.

## curl.sh — pick your packages

```
bash <(curl -Ss https://raw.githubusercontent.com/mkolakowski/curl/main/curl.sh)
```

Run it with no arguments and you get a checklist showing what's already on the
box. Type numbers to toggle things on, hit Enter, and it installs them.

```
      #   name        installed     what it is
  ------------------------------------------------------------------------
  [ ] 1   update      -             apt update && apt full-upgrade
  [x] 2   git         2.43.0        version control
  [ ] 3   screen      4.09.01       detachable terminal sessions
  [x] 4   btop        no            resource monitor
  [x] 5   docker      no            Docker Engine + Compose plugin
  [ ] 6   tailscale   no            mesh VPN
  [ ] 7   claude      no            Claude Code + boot session (runs claude.sh)

  numbers toggle · a=all · m=missing only · n=none · q=quit
Install [Enter to confirm]:
```

`m` is the useful one on a box you've half set up already — it ticks everything
that isn't there yet and leaves the rest alone.

You can also name things directly and skip the menu entirely:

```
bash <(curl -Ss .../curl.sh) install git docker
bash <(curl -Ss .../curl.sh) install missing
bash <(curl -Ss .../curl.sh) install all
bash <(curl -Ss .../curl.sh) list
```

Everything is idempotent — anything already present is reported and skipped, so
re-running costs nothing. Installs happen in catalog order, so the system update
runs first and `git` lands before anything that wants it.

Two things need a human afterwards and the script says so at the time: `sudo
tailscale up` to join your tailnet, and logging out and back in for the `docker`
group to take effect.

### Commands

| Command | Action |
| ------ | ------ |
| *(none)* | interactive checklist |
| `install <name>...` | install the named entries, no prompting |
| `install all` | install everything |
| `install missing` | install whatever isn't there yet |
| `list` | show the catalog and what's already installed |
| `update` | `apt update` + `full-upgrade` only |
| `reboot` | reboot the machine |
| `help` | usage |

Bare names work as shorthand, so `curl.sh docker` is the same as `curl.sh
install docker`.

## claude.sh — headless Claude Code

```
bash <(curl -Ss https://raw.githubusercontent.com/mkolakowski/curl/main/claude.sh)
```

On a fresh box this installs what it needs (git, screen, cron, Claude Code),
writes the session files, and starts the session. If a session is already
running it shows a menu instead of reinstalling anything:

```
A Claude Code session is already running.
  session   4711.claude	(07/27/26 10:14:02)	(Detached)
  workdir   /home/matt/work
  boot      /home/matt/.local/bin/claude-session-boot.sh

  1) Enter    attach to the running session
  2) Restart  stop it and start a fresh one
  3) Stop     stop it and exit
  4) Install  skip the menu, re-run the setup
  5) Quit     leave everything alone
```

### What it leaves behind

`~/.config/claude-session.env` holds the settings. Written once, never
overwritten — edit it freely.

`~/.local/bin/claude-session-boot.sh` is the script that actually launches
Claude Code. It's written as a **stub**, with a marked-off block in the middle
for your own pre-launch steps — waiting for the network, pulling a repo,
exporting a key, bringing containers up. Once it exists the script won't
overwrite it; if the packaged stub has changed you get a `.new` file alongside
and your version stays put.

```bash
# ---8<--- EDIT BELOW — your own pre-launch steps (stub) ---8<---
#   sleep 20
#   git -C "$WORK_DIR" pull --ff-only
#   export ANTHROPIC_API_KEY="$(cat "$HOME/.config/anthropic.key")"
# ---8<--- EDIT ABOVE ---8<---
```

A `@reboot` crontab entry runs that boot script on every boot, logging to
`~/.local/state/claude-session-boot.log`. The boot script is itself idempotent —
if a session with the configured name is already up it exits without starting a
second one.

### Commands

| Command | Action |
| ------ | ------ |
| *(none)* | menu if a session is running, otherwise install + start |
| `install` | install Claude Code and write the session files |
| `start` | launch the session via the boot script |
| `enter` | attach to the running session |
| `restart` | stop and relaunch the session |
| `stop` | stop the session |
| `status` | show config and session state |
| `uninstall` | remove the boot script and `@reboot` entry (leaves packages) |
| `help` | usage |

### Configuration

Set these in the environment or in `~/.config/claude-session.env`. The
environment wins, then the config file, then the default.

| Variable | Default | Meaning |
| ------ | ------ | ------ |
| `WORK_DIR` | `$HOME/work` | directory Claude Code is launched in |
| `SESSION_NAME` | `claude` | name of the `screen` session |
| `CLAUDE_CMD` | `claude` | command used to launch Claude Code |
| `ASSUME_YES` | *unset* | never prompt, take every default |

```
WORK_DIR=/srv/projects bash <(curl -Ss .../claude.sh) install
```

On a first install with no `WORK_DIR` set, it asks where you want to work and
defaults to `~/work`.

## Notes

Run both as your normal user, not as root — they call `sudo` where needed and
deliberately install Claude Code, the config, and the crontab entry as *you*. If
you do run them under `sudo`, they follow `$SUDO_USER` back to your account
rather than dumping everything in `/root`.

Attach to the session by hand any time with `screen -r claude`, and detach again
with <kbd>Ctrl-a</kbd> <kbd>d</kbd>.

`NO_COLOR=1` turns off colour in both scripts.

## archive/

The previous contents of this repo — the old interactive `curl.sh` menu,
`old_curl.sh`, `backup_test.sh`, and the `01-custom-motd` snippet — live in
[`archive/`](archive/), unchanged.
