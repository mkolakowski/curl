# curl

One command to take a fresh Ubuntu box and turn it into a machine that runs
Claude Code headlessly, in a detached `screen` session that comes back by itself
after a reboot.

```
bash <(curl -Ss https://raw.githubusercontent.com/mkolakowski/curl/main/curl.sh)
```

Run it with no arguments and it does the sensible thing: if nothing is set up
yet it provisions the machine and starts a session, and if a session is already
running it shows you a menu instead of reinstalling anything.

```
A Claude Code session is already running.
  session   4711.claude	(07/27/26 10:14:02)	(Detached)
  workdir   /home/matt/work
  boot      /home/matt/.local/bin/claude-session-boot.sh

  1) Enter    attach to the running session
  2) Restart  stop it and start a fresh one
  3) Stop     stop it and exit
  4) Install  skip the menu, re-run provisioning
  5) Quit     leave everything alone
```

## What it installs

Git goes first, since everything else tends to want it, and then the rest in
order: `screen`, `curl`, `cron`, `btop` (falling back to `htop` on releases that
don't carry it), Docker Engine with the Compose plugin from Docker's own apt
repo, Tailscale, and Claude Code via the native installer. Ubuntu itself gets an
`apt update && apt upgrade` before any of it.

Every step checks before it acts, so re-running the script is cheap — already
installed things report `skip` and nothing gets clobbered. That includes the
apt keyring, the Docker source list, the crontab entry, and your copy of the
boot script.

Two things need a human afterwards and the script tells you so: `sudo tailscale
up` to join your tailnet, and logging out and back in for the `docker` group to
take effect.

## The boot session

Provisioning leaves three things behind:

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

## Commands

| Command | Action |
| ------ | ------ |
| *(none)* | menu if a session is running, otherwise install + start |
| `install` | run every provisioning step |
| `start` | launch the session via the boot script |
| `enter` | attach to the running session |
| `restart` | stop and relaunch the session |
| `stop` | stop the session |
| `status` | show config, tooling and session state |
| `update` | `apt update` + `upgrade` only |
| `reboot` | reboot the machine |
| `uninstall` | remove the boot script and `@reboot` entry (leaves packages) |
| `help` | usage |

```
bash <(curl -Ss https://raw.githubusercontent.com/mkolakowski/curl/main/curl.sh) status
bash <(curl -Ss https://raw.githubusercontent.com/mkolakowski/curl/main/curl.sh) restart
```

## Configuration

Set these in the environment or in `~/.config/claude-session.env`. The
environment wins, then the config file, then the default.

| Variable | Default | Meaning |
| ------ | ------ | ------ |
| `WORK_DIR` | `$HOME/work` | directory Claude Code is launched in |
| `SESSION_NAME` | `claude` | name of the `screen` session |
| `CLAUDE_CMD` | `claude` | command used to launch Claude Code |
| `ASSUME_YES` | *unset* | never prompt, take every default |

```
WORK_DIR=/srv/projects bash <(curl -Ss https://raw.githubusercontent.com/mkolakowski/curl/main/curl.sh) install
```

On a first install with no `WORK_DIR` set, the script asks where you want to
work and defaults to `~/work`.

## Notes

Run it as your normal user, not as root — it calls `sudo` where it needs to and
deliberately installs Claude Code, the config, and the crontab entry as *you*.
If you do run it under `sudo`, it follows `$SUDO_USER` back to your account
rather than dumping everything in `/root`.

Attach to the session by hand any time with `screen -r claude`, and detach again
with <kbd>Ctrl-a</kbd> <kbd>d</kbd>.

## archive/

The previous contents of this repo — the old interactive `curl.sh` menu,
`old_curl.sh`, `backup_test.sh`, and the `01-custom-motd` snippet — now live in
[`archive/`](archive/), unchanged.
