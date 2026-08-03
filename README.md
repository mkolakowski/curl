# curl

One bash script that sets up an Ubuntu box: **packages**, **container stacks**,
and **Claude Code sessions that run unattended**. Meant to be run straight off
the web with nothing installed first.

```bash
bash <(curl -Ss https://raw.githubusercontent.com/mkolakowski/curl/main/curl.sh)
```

With no arguments you get a home menu, each row opening its own submenu:

```
  c   Claude sessions  3 running, 0 failed
  d   Docker           1 running, 2 idle
  s   Software         8 of 8 installed

  o = doctor · ? = help · q = quit
Choice:
```

| Key | Domain | What it is |
| --- | --- | --- |
| `s` | [Software](#software) | a checklist of tools; tick what you want, it installs them |
| `d` | [Containers](#docker-containers) | docker compose stacks, managed in place under `/opt/stacks` |
| `c` | [Claude sessions](#claude-sessions) | one `tmux` session per project, started at boot by systemd |

One keypress, no Enter — `c`, `d`, `s`, `o` and `q` act as soon as you press
them, and Enter on its own redraws. The submenus still read a line, because they
take numbers and lists like `2,4,5`. Everything is **idempotent**: anything
already present is reported and skipped, so re-running costs nothing.

> [!NOTE]
> Sessions were a separate script, `claude.sh`, until 4.1.0, and that URL
> forwarded here until 10.0.0, when it was removed. `claude.sh list` is now
> `curl.sh session list`.

## Software

Run with no arguments and pick `s`, and you get a checklist of what is already
on the box. Type numbers to toggle, Enter to install.

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

Or skip the menu entirely:

```bash
bash <(curl -Ss .../curl.sh) install git docker
bash <(curl -Ss .../curl.sh) install missing
bash <(curl -Ss .../curl.sh) list
```

| Command | Action |
| --- | --- |
| *(none)* | interactive checklist |
| `install <name>...` | install the named entries, no prompting |
| `install all` / `install missing` | everything, or only what isn't there yet |
| `list` | show the catalog and what's already installed |
| `update` | `apt update` + `full-upgrade` only |
| `reboot` | reboot the machine |
| `help` | usage |

Bare names are shorthand, so `curl.sh docker` is `curl.sh install docker`.
Installs happen in catalog order, so the system update runs first and `git`
lands before anything that wants it.

Three things need a human afterwards, and the script says so at the time: `sudo
tailscale up`, `gh auth login`, and logging out and back in for the `docker`
group to take effect.

<details>
<summary><b>purplemux</b> — prerequisites, and running it as a service</summary>

[purplemux](https://github.com/subicura/purplemux) is a web-native terminal
multiplexer for Claude Code. It needs `tmux` and Node.js 20+, and Ubuntu ships
an older `nodejs`, so the entry installs `tmux` from apt and Node from
NodeSource when the box's is too old — Node already at 20 or newer is left
alone. Start it with `purplemux` and open `http://localhost:8022`.

Run by hand it lives only as long as the terminal does, so the entry offers to
write and enable `/etc/systemd/system/purplemux.service`. That unit runs as you
rather than as root — purplemux keeps its config, workspaces and CLI token in
`~/.purplemux` — and sets a `PATH` including `~/.local/bin`, where Claude Code
lives and where systemd does not look by default. Say no and nothing is written;
`curl.sh purplemux-service` adds it later. A unit you had already hand-edited is
kept as `purplemux.service.bak` rather than overwritten silently.

> [!WARNING]
> purplemux advertises the machine's IP address, so reach it over Tailscale or
> a Cloudflare Tunnel rather than opening the port to the world. The first run
> also wants onboarding in a browser, so open the port once and finish setup
> there.

</details>

## Docker containers

`d` at the home menu opens a submenu for container stacks, with the same
toggle-by-number picker:

```
      #   container      state     what it is
  ------------------------------------------------------------------------
  [x] 1   cloudflared    -         Cloudflare Tunnel connector
  [ ] 2   beszel-agent   running   Beszel monitoring agent (reports to a hub)
  [x] 3   dockge         -         web UI for docker compose stacks, on port 5001
```

Each is written as a compose stack under `/opt/stacks/<name>/` — the same
directory Dockge manages, so anything installed this way shows up in Dockge
ready to edit, start and stop. `CURL_SH_STACKS_DIR` puts them elsewhere, and
Docker itself is installed first if it isn't already there.

The submenu manages a stack for its whole life, on a single keypress, so nothing
runs unless you press its letter:

| Key | Action |
| --- | --- |
| `1`-`9` | tick a stack |
| `a` / `n` | tick all / clear all |
| `i` | install the ticked stacks |
| `s` / `x` / `r` | start / stop / restart |
| Enter | redraw |
| `q` | back |

The same verbs work on the command line, and a bare verb acts on every installed
stack:

```bash
bash <(curl -Ss .../curl.sh) containers               # the checklist
bash <(curl -Ss .../curl.sh) containers dockge        # install one
bash <(curl -Ss .../curl.sh) containers restart       # restart everything
bash <(curl -Ss .../curl.sh) containers stop dockge   # one stack
```

Stacks needing a secret ask for it and write a `chmod 600` `.env` beside the
compose file, so nothing sensitive lands in the compose file or your shell
history. Press Enter to skip and the stack is written with `REPLACE_ME` and left
stopped, with the script naming the file to finish.

## Claude sessions

```bash
bash <(curl -Ss https://raw.githubusercontent.com/mkolakowski/curl/main/curl.sh) session
```

Runs any number of Claude Code sessions — one per project folder, each in its
own `tmux` session, started at boot by systemd and restarted if it dies. On a
fresh box it installs what it needs (git, tmux, Claude Code), asks where you
want to work, and starts your first session. After that:

```
  #   session       state     boot   remote   yolo  work directory
  ----------------------------------------------------------------------------
  1   site          running   auto   -        yes   ~/GitHub/site
  2   api           running   auto   server   yes   ~/GitHub/api
  3   scratch       stopped   manual -        NO    /tmp/scratch

  number = manage that one · n = new session · s = start all · r = restart all
  x = stop all · y = sync systemd with the config · q = quit
```

Pick a number to manage one session. Its entries depend on its state — a stopped
session offers Start, a running one Enter, Restart and Stop — so the default is
always the thing you came for. Remote cycles off → server → interactive, Yolo
and Boot toggle, Logs shows what it has printed.

`n` creates a session (the same flow as `curl.sh session new`), asking in turn
for a name, a working directory, and whether it should autostart, skip
permission prompts and be remotely reachable. The directory question offers to
clone a GitHub repo, taking `owner/repo` or a full `https://` or `git@` URL; a
destination that is already a clone is used as it is rather than failing.

### The registry

Sessions live one per line in `~/.config/claude-sessions.conf`, plain enough to
edit by hand:

```
# name        work directory                    flags
site          /home/matt/GitHub/site            autostart yolo
api           /home/matt/GitHub/api             autostart yolo remote
scratch       /tmp/scratch                      noautostart noyolo
```

Flags come in any order and each has a default, so `site /home/matt/site` on its
own means autostart and yolo. Work directories may not contain spaces; `~` is
expanded.

| Flag | Default | Meaning |
| --- | --- | --- |
| `autostart` / `noautostart` | `autostart` | whether systemd enables it, so it comes up on boot |
| `yolo` / `noyolo` | `yolo` | pass `--dangerously-skip-permissions` |
| `local` / `remote` / `remote-interactive` | `local` | [Remote Control](#remote-control) mode |

Adding a project is one line plus `curl.sh session sync`. That is the whole
extension story: **one** templated unit, `claude-session@<name>.service`, serves
every session, so a new folder never means writing or editing a unit file.

```bash
bash <(curl -Ss .../curl.sh) session add api ~/GitHub/api
bash <(curl -Ss .../curl.sh) session add scratch /tmp/scratch --no-autostart --no-yolo
bash <(curl -Ss .../curl.sh) session sync
bash <(curl -Ss .../curl.sh) session rm scratch
```

`sync` is what you run after editing the file by hand: it enables the units for
everything marked `autostart`, disables the rest, and retires units left over
from sessions you deleted — those would otherwise come back on the next boot and
fail.

> [!CAUTION]
> **Yolo is the default, deliberately.** Nobody is sitting there, and a session
> that stops at a permission prompt stops for good — you find out hours later
> when nothing has happened. So sessions run with
> `--dangerously-skip-permissions` unless marked `noyolo`, and the table prints
> a yellow `NO` for any session that isn't. That flag is exactly what it says:
> these sessions can run any command in their working directory without asking.
> Give each one a folder you are happy to hand over, and reach for `noyolo` on
> anything you aren't.

### Attaching

```
tmux attach -t claude-<name>          detach again with Ctrl-b d
tmux ls                               every session on the box
curl.sh session attach <name>         the same thing, across a sudo boundary
```

Sessions are named `claude-<name>` on tmux's default socket, so a plain `tmux
ls` shows them all. `curl.sh session attach` exists because the tmux server
belongs to whoever started it — as root you would be talking to root's server
and see nothing.

### Auth

Sessions never prompt for credentials, and the script never tries to sign you
in. Do it once by hand with `claude auth login`, or put `ANTHROPIC_API_KEY` in
`~/.config/claude-sessions.env` or `/etc/claude-sessions.env`, which the unit
reads if present and ignores if not (`chmod 600` them).

Remote Control needs the claude.ai login specifically and refuses API keys, so
the two are not interchangeable. `curl.sh doctor` reports which you have.

### Remote control

A session can be reachable from [claude.ai/code](https://claude.ai/code) and the
Claude mobile app while it keeps running here, against this filesystem. There
are two modes, because Claude Code offers two:

```bash
bash <(curl -Ss .../curl.sh) session remote api on           # server mode
bash <(curl -Ss .../curl.sh) session remote api interactive  # interactive + remote
bash <(curl -Ss .../curl.sh) session remote api off
```

**`on` is server mode** — `claude remote-control`. The session exists to be
driven from your phone or browser; there is no local prompt, and attaching shows
connection status and tool activity. It refuses to start at all if Remote
Control can't connect, which is what you want on a headless box.

**`interactive`** is `claude --remote-control` — an ordinary session that is
*also* reachable remotely, so you can type on the box and from your phone
interchangeably. The catch: it does **not** fail when Remote Control can't
connect. It quietly carries on as a normal local session and shows a
notification you never see from a detached pane.

Either mode needs a claude.ai login on a Pro, Max, Team or Enterprise plan. API
keys are not supported, so `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN` and
`ANTHROPIC_BASE_URL` must all be unset — the script checks first and says what
is wrong, then reads the pane a few seconds after launch to confirm it really
connected, printing the session URL if it did.

<details>
<summary>Why yolo works differently in server mode</summary>

`--dangerously-skip-permissions` is a top-level option of `claude`, so a `yolo`
session gets it on the plain and `--remote-control` forms. Server mode is a
*subcommand*, and passing it a flag it doesn't know would make it exit instantly
— which `Restart=always` would turn into a five-second loop. So the wrapper asks
`claude remote-control --help` first and only passes the flag if it is
advertised, noting it in the log when it isn't.

</details>

### When a session doesn't come up

```bash
bash <(curl -Ss .../curl.sh) session doctor
bash <(curl -Ss .../curl.sh) session logs <name>
```

`doctor` reports the Claude Code and tmux versions, whether systemd and the unit
are there, whether you are signed in or have a key, any environment variable
Remote Control rejects, and for each session its unit state and what is on its
pane:

```
  claude.ai login        not signed in  (run once: claude auth login)

  Sessions
    api           remote:server  stopped   yolo
      unit: failed, enabled
      last output before it exited:
        Remote Control requires a claude.ai subscription
```

Standard systemd works too — `claude-session@site.service` is the templated unit
with `%i` substituted:

```bash
systemctl status claude-session@site
journalctl -u claude-session@site -n 50
journalctl -u 'claude-session@*' -f
```

<details>
<summary>How boot and crash resilience actually work</summary>

`ExecStart` is `~/.local/bin/claude-session-run.sh <name>`, a wrapper that
creates the tmux session and then blocks for as long as it lives. Hence
`Type=simple` with `Restart=always` rather than `Type=forking`: tmux
double-forks to its server, so a forking unit loses track of what it is
supervising almost immediately. With a wrapper that blocks, the session ending
*is* the process exiting.

Two things stop a session that dies on startup from restarting forever. The
wrapper exits **78** for anything restarting cannot fix — a name not in the
registry, an unreadable config, an uncreatable working directory — and
`RestartPreventExitStatus` stops there. Everything else is a crash worth
retrying, bounded by `StartLimitBurst=5` in five minutes before the unit reports
`failed`.

All sessions share one tmux server, which is what makes the plain `tmux attach`
above work, so the unit uses `KillMode=process` and an `ExecStop` that kills only
its own session. Stopping one never takes everyone else's down with it.

</details>

### What it leaves behind

| Path | What |
| --- | --- |
| `~/.config/claude-sessions.conf` | the registry above |
| `~/.local/bin/claude-session-run.sh` | the wrapper systemd runs |
| `~/.local/state/claude-sessions/<name>.log` | live output, rotated at 5 MB |
| `~/.local/state/claude-sessions/<name>.screen` | last screenful, refreshed every few seconds |

The runner is written as a **stub**, with a marked-off block for your own
pre-launch steps — pulling a repo, bringing containers up:

```sh
# ---8<--- EDIT BELOW — your own pre-launch steps (stub) ---8<---
#   cd "$HOME/GitHub/$NAME" && git pull --ff-only
#   docker compose -f "$HOME/work/compose.yaml" up -d
# ---8<--- EDIT ABOVE ---8<---
```

It records a checksum of what was written, so an untouched stub is upgraded in
place when the packaged version changes; once you edit it, it is never
overwritten and you get a `.new` file alongside instead.

Output is captured two ways because neither alone is enough: the `.log` is the
live stream, and the `.screen` is what survives when a session dies in its first
instant, before anything has attached. The pane outlives its command by five
seconds and prints the exit status, so `[claude-session] api exited with status
1` ends up in both.

### Session commands

| Command | Action |
| --- | --- |
| *(none)* | the table, then pick a session, press `n`, or act on all |
| `install` | install Claude Code, the runner and the unit |
| `new` | register a session, prompting for each answer |
| `add <name> <dir> [--no-autostart] [--no-yolo] [--remote]` | register a session |
| `rm <name>` | unregister it, stop it, disable its unit |
| `list` | print the table and exit |
| `sync` | make systemd match the registry after editing it by hand |
| `start` / `stop` / `restart` `[name...]` | named sessions, or every autostart one |
| `attach [name]` | attach; the name may be omitted if only one is running |
| `logs [name]` | tail what a session has printed |
| `remote <name> on\|interactive\|off` | Remote Control: server, interactive, or off |
| `yolo <name> on\|off` | `--dangerously-skip-permissions` for that session |
| `autostart <name> on\|off` | whether systemd starts it at boot |
| `status` | table plus registry, unit and Claude Code state |
| `doctor [name]` | why a session is not running or not connecting |
| `migrate` | clear screen-era leftovers |
| `uninstall` | remove the unit and the runner (leaves packages and the registry) |
| `-v`, `--verbose` | trace each step with timings, to pin down a stall |
| `help` | usage |

<details>
<summary>Upgrading from the screen version</summary>

Earlier versions ran sessions under `screen` from an `@reboot` crontab entry.
Upgrading migrates automatically, and `curl.sh session migrate` does it on
demand:

- the `@reboot` entry is removed — **only** ours; anything else in your crontab
  is left exactly where it is
- `~/.local/bin/claude-session-boot.sh` is retired to `.retired`, not deleted
- screen sessions named after registered projects are stopped, since they would
  otherwise hold the same working directory as the new tmux one. Ones we don't
  recognise are not touched
- your registry carries over unchanged, and every session picks up the new
  `yolo` default

`curl.sh session status` says so if any of it is still lying around.

</details>

## Reference

| Variable | Default | Meaning |
| --- | --- | --- |
| `CURL_SH_STACKS_DIR` | `/opt/stacks` | where compose stacks are written |
| `CURL_SH_PMUX_PORT` | `8022` | port for the purplemux service |
| `CLAUDE_SESSIONS_CONF` | `~/.config/claude-sessions.conf` | registry path |
| `CLAUDE_CMD` | `claude` | command used to launch Claude Code |
| `ASSUME_YES` | *unset* | never prompt, take every default |
| `NO_COLOR` | *unset* | plain output, no colour |

Run it as your normal user, not as root: it calls `sudo` where needed and
deliberately installs Claude Code and its config as *you*. The systemd unit
needs root to write, but carries `User=` and runs sessions under your account.
Run the whole thing under `sudo` anyway and it follows `$SUDO_USER` back to you
rather than dumping everything in `/root`.

## archive/

The previous contents of this repo — the old interactive `curl.sh` menu,
`old_curl.sh`, `backup_test.sh`, and the `01-custom-motd` snippet — live in
[`archive/`](archive/), unchanged.
