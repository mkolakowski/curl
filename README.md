# curl

One script for setting up an Ubuntu box, meant to be run straight off the web
with nothing installed first.

```
bash <(curl -Ss https://raw.githubusercontent.com/mkolakowski/curl/main/curl.sh)
```

With no arguments you get a menu of three things, each opening its own submenu:

```
  c   Claude sessions  3 running, 0 failed
  d   Docker           1 running, 2 idle
  i   Installers       8 of 8 installed

  o = doctor · ? = help · q = quit
Choice:
```

One keypress, no Enter — `c`, `d`, `i`, `o` and `q` act as soon as you press
them. Enter on its own redraws. The submenus still read a line, because they
take numbers and lists like `2,4,5`.

- **installers** — a checklist of tools; tick what you want, it installs them
- **containers** — docker compose stacks, managed in place under `/opt/stacks`
- **claude sessions** — Claude Code unattended: one `tmux` session per project
  folder, started at boot by systemd and restarted if it dies

The sessions were a separate script, [`claude.sh`](claude.sh), until 4.1.0.
That URL still works — it forwards to `curl.sh session` — so `claude.sh list`
and `curl.sh session list` are the same thing.

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
  [ ] 9   claude      no            Claude Code + unattended tmux sessions

  numbers toggle · a=all · m=missing only · n=none · q=back
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

Run by hand it lives only as long as the terminal does, so once it is installed
the entry asks whether to also run it as a service. Say yes and it writes
`/etc/systemd/system/purplemux.service` and enables it, so purplemux comes back
after a reboot. The unit runs as you rather than as root — purplemux keeps its
config, workspaces and CLI token in `~/.purplemux` — and sets a `PATH` that
includes `~/.local/bin`, which is where Claude Code lives and is not somewhere
systemd looks by default. Say no and nothing is written; `curl.sh
purplemux-service` adds it later. `CURL_SH_PMUX_PORT` picks a port other than
8022.

Two things are worth knowing before enabling it. The first run still wants
onboarding in a browser, so open the port once and finish setup there. And
purplemux advertises the machine's IP address, so reach it over Tailscale or a
Cloudflare Tunnel rather than opening the port to the world. If you had already
hand-edited the unit, your version is kept as `purplemux.service.bak` rather
than being overwritten silently.

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
screen — `i` installs, `s` starts, `x` stops, `r` restarts — so the submenu
manages a stack for its whole life, not just the first five minutes. It acts on
a single keypress: `1`-`9` tick a stack, `a` ticks all, `n` clears, Enter
redraws and `q` goes back, so nothing runs unless you press its letter. The same
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

## curl.sh session — unattended Claude Code

```
bash <(curl -Ss https://raw.githubusercontent.com/mkolakowski/curl/main/curl.sh) session
```

The old `claude.sh` URL still works and forwards here, so every `claude.sh`
command below can be spelled either way.

Runs any number of Claude Code sessions on the box — one per project folder,
each in its own `tmux` session, each started at boot by systemd and restarted if
it dies. On a fresh box it installs what it needs (git, tmux, Claude Code), asks
where you want to work, and starts your first session. After that, running it
with no arguments gives you the table:

```
  #   session       state     boot   remote   yolo  work directory
  ----------------------------------------------------------------------------
  1   site          running   auto   -        yes   ~/GitHub/site
  2   api           running   auto   server   yes   ~/GitHub/api
  3   scratch       stopped   manual -        NO    /tmp/scratch

  number = manage that one · n = new session · s = start all · r = restart all
  x = stop all · y = sync systemd with the config · q = quit
```

Pick a number to manage a session. The entries depend on its state — a stopped
session offers Start, a running one Enter, Restart and Stop — so the default is
always the thing you came for. Remote cycles off → server → interactive; Yolo
and Boot toggle; Logs shows what the session has printed. `s`, `r`, `x` and `y`
act on everything at once. `n` creates a new session, asking for each answer in
turn:

```
Session name: api

  Where should it work?
  1) /home/matt/GitHub/api
  2) /home/matt/work/api
  3) clone a GitHub repo into /home/matt/GitHub/
  4) somewhere else (type the path)
  Choice [1]: 3
    owner/repo (or a full git URL): mkolakowski/api

  Start it automatically at boot? [Y/n]: y
  Skip permission prompts (--dangerously-skip-permissions)? [Y/n]: y

  Remote Control?
  1) no — a plain local session
  2) server mode — drive it from claude.ai/code, no local prompt
  3) interactive — reachable remotely and usable on the box
  Choice [1]: 2

  Start 'api' now? [Y/n]: y
```

The same flow is `claude.sh new`. `owner/repo` and full `https://` or `git@`
URLs all work for the clone option; a destination that is already a clone is
used as it is rather than failing.

### Sessions

Sessions live one per line in `~/.config/claude-sessions.conf`, which is plain
enough to edit by hand:

```
# name        work directory                    flags
site          /home/matt/GitHub/site            autostart yolo
api           /home/matt/GitHub/api             autostart yolo remote
scratch       /tmp/scratch                      noautostart noyolo
```

Adding a project is one line plus `claude.sh sync`. That is the whole extension
story: **one** templated unit, `claude-session@<name>.service`, serves every
session, so a new folder never means writing or editing a unit file.

Flags can appear in any order, and each has a default, so `site /home/matt/site`
on its own means autostart and yolo. Work directories may not contain spaces;
`~` is expanded.

| Flag | Default | Meaning |
| ------ | ------ | ------ |
| `autostart` / `noautostart` | `autostart` | whether systemd enables it, so it comes up on boot |
| `yolo` / `noyolo` | `yolo` | pass `--dangerously-skip-permissions` |
| `local` / `remote` / `remote-interactive` | `local` | Remote Control mode, below |

```
bash <(curl -Ss .../claude.sh) new
bash <(curl -Ss .../claude.sh) add api ~/GitHub/api
bash <(curl -Ss .../claude.sh) add scratch /tmp/scratch --no-autostart --no-yolo
bash <(curl -Ss .../claude.sh) sync
bash <(curl -Ss .../claude.sh) rm scratch
```

`sync` is what you run after editing the file by hand: it enables the units for
everything marked `autostart`, disables the rest, and retires units left over
from sessions you have deleted — those would otherwise come back on the next
boot and fail.

### Why yolo is the default

Nobody is sitting there. A session that stops at a permission prompt stops for
good, and you find out hours later when nothing has happened. So sessions run
with `--dangerously-skip-permissions` unless you mark one `noyolo`, and the
table prints a yellow `NO` for any session that isn't, because that session will
eventually stall on a prompt no one answers.

That flag is exactly what it says. These sessions can run any command in their
working directory without asking, so give each one a folder you are happy to
hand over, and reach for `noyolo` on anything you aren't.

### Attaching

```
tmux attach -t claude-<name>      detach again with Ctrl-b d
tmux ls                           every session on the box
claude.sh attach <name>           the same thing, across a sudo boundary
```

Sessions are named `claude-<name>` on tmux's default socket, so a plain `tmux
ls` shows them all and no extra flags are needed to attach. `claude.sh attach`
exists because the sessions belong to *your* account: as root you would
otherwise be talking to root's tmux server and see nothing.

### Boot and crash resilience

One templated unit does all of it:

```
/etc/systemd/system/claude-session@.service
```

`claude-session@site.service` and `claude-session@api.service` are that same
file with `%i` substituted. Standard systemd from there:

```
systemctl status claude-session@site
systemctl restart claude-session@site
journalctl -u claude-session@site -n 50
journalctl -u 'claude-session@*' -f
```

`ExecStart` is `~/.local/bin/claude-session-run.sh <name>`, a wrapper that
creates the tmux session and then stays in the foreground for as long as it
lives. That is why the unit is `Type=simple` with `Restart=always` rather than
`Type=forking`: tmux double-forks to its server, so a forking unit loses track
of what it is meant to be supervising almost immediately. With a wrapper that
blocks, the session ending *is* the process exiting, and systemd restarts it
without needing to understand tmux at all.

A session that dies on startup would otherwise restart every five seconds
forever, so two things bound it. The wrapper exits **78** for anything that
restarting cannot fix — a name that isn't in the registry, an unreadable config,
a working directory it can't create — and the unit's `RestartPreventExitStatus`
stops there. Everything else is treated as a crash worth retrying, with
`StartLimitBurst=5` in five minutes before the unit gives up and reports
`failed`, which the table shows.

All sessions share one tmux server, which is what makes the plain `tmux attach`
above work. The unit therefore uses `KillMode=process` and an explicit
`ExecStop` that kills only its own session, so stopping one never takes the
server — and everyone else's sessions — down with it.

### Auth

Sessions never prompt for credentials, and the script never tries to sign you
in. Do it once, by hand:

```
claude auth login
```

Or provide `ANTHROPIC_API_KEY` through either of these, which the unit reads if
present and ignores if not (`chmod 600` them):

```
~/.config/claude-sessions.env
/etc/claude-sessions.env
```

Remote Control specifically needs the claude.ai login and refuses API keys, so
the two are not interchangeable — see below. `claude.sh doctor` reports which of
the two you have.

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
driven from your phone or browser; there is no local prompt, and attaching shows
connection status and tool activity. It refuses to start at all if Remote
Control can't connect, which is what you want on a headless box.

`interactive` is `claude --remote-control` — an ordinary session that is *also*
reachable remotely, so you can type on the box and from your phone
interchangeably. The catch is that it does **not** fail when Remote Control
can't connect: it quietly carries on as a normal local session and shows a
notification you never see from a detached pane.

Either way it needs a claude.ai login on a Pro, Max, Team or Enterprise plan.
API keys are not supported, so `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`
and `ANTHROPIC_BASE_URL` must all be unset.

The script checks these before starting a remote session and says what is wrong,
then reads the session's pane a few seconds after launch to confirm it really
connected — printing the session URL if it did.

One wrinkle worth knowing: `--dangerously-skip-permissions` is a top-level
option of `claude`, so a `yolo` session gets it on the plain and
`--remote-control` forms. Server mode is a *subcommand*, and passing it a flag
it doesn't know would make it exit instantly — which `Restart=always` would turn
into a five-second loop. So the wrapper asks `claude remote-control --help`
first and only passes the flag if it is advertised, noting it in the log when it
isn't.

### When a session doesn't come up

```
bash <(curl -Ss .../claude.sh) doctor
bash <(curl -Ss .../claude.sh) logs <name>
```

`doctor` reports the Claude Code and tmux versions, whether systemd and the unit
are there, whether you are signed in or have a key, any environment variable
that Remote Control rejects, and for each session its unit state and what is on
its pane:

```
  claude.ai login        not signed in  (run once: claude auth login)

  Sessions
    api           remote:server  stopped   yolo
      unit: failed, enabled
      last output before it exited:
        Remote Control requires a claude.ai subscription
        [claude-session] api exited with status 1
```

### What it leaves behind

`~/.config/claude-sessions.conf` is the registry above.

`~/.local/bin/claude-session-run.sh` is the wrapper systemd runs. It's written
as a **stub**, with a marked-off block for your own pre-launch steps — pulling a
repo, bringing containers up. It records a checksum of what was written, so an
untouched stub is upgraded in place when the packaged version changes; once you
edit it, it is never overwritten and you get a `.new` file alongside instead.

```sh
# ---8<--- EDIT BELOW — your own pre-launch steps (stub) ---8<---
#   cd "$HOME/GitHub/$NAME" && git pull --ff-only
#   docker compose -f "$HOME/work/compose.yaml" up -d
# ---8<--- EDIT ABOVE ---8<---
```

Each session's output is captured two ways, because neither alone is enough.
`~/.local/state/claude-sessions/<name>.log` is the live stream, rotated at 5 MB
so `Restart=always` can't fill the disk. `<name>.screen` is the last screenful,
refreshed every few seconds — which is what survives when a session dies in its
first instant, before anything has attached to its output. The pane also
outlives its command by five seconds and prints the exit status, so
`[claude-session] api exited with status 1` ends up in both.

### Upgrading from the screen version

Earlier versions ran sessions under `screen` from an `@reboot` crontab entry.
Upgrading migrates automatically, and `claude.sh migrate` does it on demand:

- the `@reboot` entry is removed — **only** ours; anything else in your crontab
  is left exactly where it is
- `~/.local/bin/claude-session-boot.sh` is retired to `.retired` rather than
  deleted
- screen sessions named after registered projects are stopped, since they would
  otherwise sit there holding the same working directory as the new tmux one.
  Screen sessions we don't recognise are not touched
- your registry carries over unchanged. Flags mean what they did, plus every
  session picks up the new `yolo` default

`claude.sh status` says so if any of it is still lying around.

### Commands

| Command | Action |
| ------ | ------ |
| *(none)* | the table, then pick a session, press `n`, or act on all |
| `install` | install Claude Code, the runner and the unit |
| `new` | register a session, prompting for each answer |
| `add <name> <dir> [--no-autostart] [--no-yolo] [--remote]` | register a session |
| `rm <name>` | unregister it, stop it, disable its unit |
| `list` | print the table and exit |
| `sync` | make systemd match the registry after editing it by hand |
| `start [name...]` | start the named sessions, or every autostart one |
| `stop [name...]` | stop the named sessions, or all of them |
| `restart [name...]` | stop and start again |
| `attach [name]` | attach; the name may be omitted if only one is running |
| `logs [name]` | tail what a session has printed |
| `remote <name> on\|interactive\|off` | Remote Control: server mode, interactive, or off |
| `yolo <name> on\|off` | `--dangerously-skip-permissions` for that session |
| `autostart <name> on\|off` | whether systemd starts it at boot |
| `status` | table plus registry, unit and Claude Code state |
| `doctor [name]` | why a session is not running or not connecting |
| `migrate` | clear screen-era leftovers |
| `uninstall` | remove the unit and the runner (leaves packages and the registry) |
| `-v`, `--verbose` | trace each step with timings, to pin down a stall |
| `help` | usage |

### Environment

| Variable | Default | Meaning |
| ------ | ------ | ------ |
| `CLAUDE_SESSIONS_CONF` | `~/.config/claude-sessions.conf` | registry path |
| `CLAUDE_CMD` | `claude` | command used to launch Claude Code |
| `ASSUME_YES` | *unset* | never prompt, take every default |

## Notes

Run both as your normal user, not as root — they call `sudo` where needed and
deliberately install Claude Code and its config as *you*. The systemd unit needs
root to write, but it carries `User=` and runs the sessions under your account.
If you do run these under `sudo`, they follow `$SUDO_USER` back to you rather
than dumping everything in `/root`.

Attach to a session by hand any time with `tmux attach -t claude-<name>`, and
detach again with <kbd>Ctrl-b</kbd> <kbd>d</kbd>. The tmux server belongs to
whoever started it: as root you won't see a session belonging to your own
account, so use `claude.sh attach <name>`, which crosses that boundary for you.

`NO_COLOR=1` turns off colour in both scripts.

## archive/

The previous contents of this repo — the old interactive `curl.sh` menu,
`old_curl.sh`, `backup_test.sh`, and the `01-custom-motd` snippet — live in
[`archive/`](archive/), unchanged.
