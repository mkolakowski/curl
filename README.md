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
  [x] 3   gh          no            GitHub CLI
  [ ] 4   screen      4.09.01       detachable terminal sessions
  [x] 5   btop        no            resource monitor
  [x] 6   docker      no            Docker Engine + Compose plugin
  [ ] 7   tailscale   no            mesh VPN
  [x] 8   purplemux   no            web terminal multiplexer for Claude Code
  [ ] 9   claude      no            Claude Code + boot session (runs claude.sh)

  numbers toggle · a=all · m=missing only · n=none · d=docker containers · q=quit
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

Picking `purplemux` brings its prerequisites with it. It is a
[web-native terminal multiplexer for Claude Code](https://github.com/subicura/purplemux)
that needs `tmux` and Node.js 20+, and Ubuntu ships an older `nodejs` than that,
so the entry installs `tmux` from apt and Node from NodeSource when what the box
has is too old. Node already at 20 or newer is left alone. Start it with
`purplemux` and open `http://localhost:8022`.

### Docker containers

`d` in the checklist opens a submenu for container stacks, with the same
toggle-by-number picker:

```
      #   container      state     what it is
  ------------------------------------------------------------------------
  [x] 1   cloudflared    -         Cloudflare Tunnel connector
  [ ] 2   beszel-agent   running   Beszel monitoring agent (reports to a hub)
  [x] 3   dockge         -         web UI for docker compose stacks, on port 5001
```

Each one is written as a compose stack under `/opt/stacks/<name>/` — the same
directory Dockge manages, so anything installed this way appears in Dockge ready
to edit, start and stop. Set `CURL_SH_STACKS_DIR` to put them elsewhere.

Stacks that need a secret ask for it and write a `chmod 600` `.env` beside the
compose file, so nothing sensitive lands in the compose file or your shell
history. Press Enter to skip: the stack is written with `REPLACE_ME` and left
stopped, and the script tells you which file to finish. Docker itself is
installed first if it isn't already there.

Ticked containers can also be started, stopped and restarted from the same
screen — `Enter` installs, `s` starts, `x` stops, `r` restarts — so the submenu
manages a stack for its whole life, not just the first five minutes. The same
verbs work on the command line, and a bare verb acts on every installed stack:

```
bash <(curl -Ss .../curl.sh) containers               # the checklist
bash <(curl -Ss .../curl.sh) containers dockge        # install one
bash <(curl -Ss .../curl.sh) containers restart       # restart everything
bash <(curl -Ss .../curl.sh) containers stop dockge   # one stack
```

Three things need a human afterwards and the script says so at the time: `sudo
tailscale up` to join your tailnet, `gh auth login` to sign the GitHub CLI in,
and logging out and back in for the `docker` group to take effect.

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

Runs any number of Claude Code sessions on the box, each in its own detached
`screen` with its own working directory, and brings them back after a reboot.
On a fresh box it installs what it needs (git, screen, cron, Claude Code), asks
where you want to work, and starts your first session. After that, running it
with no arguments gives you the table:

```
  #   session      state     auto  remote  work directory
  --------------------------------------------------------------------------
  1   claude       running   yes   -       /home/matt/work
  2   api          running   yes   yes     /home/matt/work/api
  3   scratch      stopped   no    -       /tmp/scratch

  number = manage that one · n = new session · s = start all · r = restart all · x = stop all · q = quit
```

Pick a number to manage a session. The entries you get depend on its state — a
stopped session offers Start, a running one Enter, Restart and Stop — so the
default is always the thing you came for, and Remote is a single entry that
cycles off → server → interactive. `s`, `r` and `x` act on everything at once. `n` creates a new
session, asking for each answer in turn:

```
New session

  Name: api

  Where should it run?
    1) /home/matt/work
    2) /home/matt/work/api
    3) /home/matt/work/web
    4) /home/matt
    5) somewhere else
    6) clone a GitHub repo
  Choice [1]: 2

  Start it automatically after a reboot? [Y/n]: y
  Enable remote control (drive it from claude.ai and the Claude app)? [y/N]: y
  Start it now? [Y/n]: y
```

The suggested directories are where you are now, your work directory and what
is under it, the parents of sessions you already have, and your home directory.
Pick "somewhere else" to type a path; a relative one resolves against the
current directory, and anything that does not exist yet is created. The same
flow is available as `claude.sh new`.

"Clone a GitHub repo" clones one first and uses it as the working directory:

```
  Repo (owner/name, or a full URL): anthropics/claude-code
  Clone into [/home/matt/work]:
  :: Cloning https://github.com/anthropics/claude-code into /home/matt/work/claude-code
```

`owner/name`, an `https://` or `git@` URL, and a local path all work. If the
GitHub CLI is installed and signed in it clones with `gh`, so private repos work
too; otherwise it falls back to `git` and says so. If the destination is already
a clone it offers to use it as it is rather than failing.

### Sessions

Sessions live one per line in `~/.config/claude-sessions.conf`, which is plain
enough to edit by hand:

```
# name        work directory                    flags
claude        /home/matt/work                   autostart
api           /home/matt/work/api               autostart remote
scratch       /tmp/scratch                      noautostart
```

`autostart` decides whether the `@reboot` entry brings a session back — leave it
off for a scratch session you don't want returning after every reboot. Flags can
appear in any order. Work directories may not contain spaces.

```
bash <(curl -Ss .../claude.sh) new
bash <(curl -Ss .../claude.sh) add api ~/work/api
bash <(curl -Ss .../claude.sh) add scratch /tmp/scratch --no-autostart
bash <(curl -Ss .../claude.sh) rm scratch
```

Upgrading from the single-session version is automatic: the old
`~/.config/claude-session.env` is folded into the registry on first run and your
existing session carries over.

### Remote control

A session can be reachable from [claude.ai/code](https://claude.ai/code) and the
Claude mobile app while it keeps running here, against this filesystem. There
are two modes, because Claude Code offers two:

```
bash <(curl -Ss .../claude.sh) remote api on           # server mode
bash <(curl -Ss .../claude.sh) remote api interactive  # interactive + remote
bash <(curl -Ss .../claude.sh) remote api off
```

`on` is **server mode** — `claude remote-control`. The session exists to be
driven from your phone or browser; there is no local prompt, and attaching to
the screen shows connection status and tool activity. It refuses to start at all
if Remote Control can't connect, which is what you want on a headless box.

`interactive` is `claude --remote-control` — an ordinary session that is *also*
reachable remotely, so you can type on the box and from your phone
interchangeably. The catch is that it does **not** fail when Remote Control
can't connect: it quietly carries on as a normal local session and shows a
notification you never see from a detached screen.

Either way it needs a claude.ai login on a Pro, Max, Team or Enterprise plan.
API keys are not supported, so `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`
and `ANTHROPIC_BASE_URL` must all be unset. Sign in once on the box:

```
claude auth login
```

The script checks these before starting a remote session and says what is
wrong, then reads the session's screen a few seconds after launch to confirm it
really connected — printing the session URL if it did.

### When a remote session doesn't appear

```
bash <(curl -Ss .../claude.sh) doctor
```

Reports the Claude Code version, whether you are signed in, any environment
variable that Remote Control rejects, what `claude doctor` says about
eligibility, and for each running remote session what is actually on its screen:

```
  claude.ai login        not signed in  (run: claude auth login)

  Remote Control eligibility
    x not signed in to claude.ai — run: claude auth login

  Sessions
    api          remote:server  running
      no session URL on screen — last lines:
        Remote Control requires a claude.ai subscription
```

### What it leaves behind

`~/.config/claude-sessions.conf` is the registry above.

`~/.local/bin/claude-session-boot.sh` is the script that actually launches the
sessions. It's written as a **stub**, with a marked-off block for your own
pre-launch steps — waiting for the network, pulling a repo, bringing containers
up. It records a checksum of what was written, so an untouched stub is upgraded
in place when the packaged version changes; once you edit it, it is never
overwritten and you get a `.new` file alongside instead.

```bash
# ---8<--- EDIT BELOW — your own pre-launch steps (stub) ---8<---
#   sleep 20
#   docker compose -f "$HOME/work/compose.yaml" up -d
# ---8<--- EDIT ABOVE ---8<---
```

Each session's own output is captured to
`~/.local/state/claude-sessions/<name>.log`, so a session that exits immediately
still leaves the reason behind — that is where a failed start gets its
explanation from. `screen` is started from the session's work directory, so a new
window inside it (<kbd>Ctrl-a</kbd> <kbd>c</kbd>) opens there too.

A `@reboot` crontab entry runs it on every boot, logging to
`~/.local/state/claude-session-boot.log`. Both the script and the stub are
idempotent — a session already up is left alone rather than started twice.

### Commands

| Command | Action |
| ------ | ------ |
| *(none)* | the table, then pick a session, press `n`, or act on all |
| `install` | install Claude Code and write the boot files |
| `new` | register a session, prompting for each answer |
| `add <name> <dir> [--no-autostart] [--remote]` | register a session |
| `rm <name>` | unregister a session (does not stop it) |
| `list` | print the table and exit |
| `start [name...]` | start the named sessions, or every autostart one |
| `stop [name...]` | stop the named sessions, or all of them |
| `restart [name...]` | stop and start again |
| `enter [name]` | attach; the name may be omitted if only one is running |
| `remote <name> on\|interactive\|off` | Remote Control: server mode, interactive, or off |
| `doctor [name]` | why a remote session is not connecting |
| `-v`, `--verbose` | trace each step with timings, to pin down a stall |
| `status` | table plus registry, cron and Claude Code state |
| `uninstall` | remove the boot script and `@reboot` entry (leaves packages) |
| `help` | usage |

### Environment

| Variable | Default | Meaning |
| ------ | ------ | ------ |
| `CLAUDE_SESSIONS_CONF` | `~/.config/claude-sessions.conf` | registry path |
| `CLAUDE_CMD` | `claude` | command used to launch Claude Code |
| `ASSUME_YES` | *unset* | never prompt, take every default |

## Notes

Run both as your normal user, not as root — they call `sudo` where needed and
deliberately install Claude Code, the config, and the crontab entry as *you*. If
you do run them under `sudo`, they follow `$SUDO_USER` back to your account
rather than dumping everything in `/root`.

Attach to a session by hand any time with `screen -r <name>`, and detach again
with <kbd>Ctrl-a</kbd> <kbd>d</kbd>. Note that screen sockets are per-user: as
root you won't see a session belonging to your own account, so use
`claude.sh enter <name>`, which crosses that boundary for you.

`NO_COLOR=1` turns off colour in both scripts.

## archive/

The previous contents of this repo — the old interactive `curl.sh` menu,
`old_curl.sh`, `backup_test.sh`, and the `01-custom-motd` snippet — live in
[`archive/`](archive/), unchanged.
