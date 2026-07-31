#!/usr/bin/env bash
#
# claude.sh — run Claude Code unattended in tmux sessions, started by systemd.
#
#   bash <(curl -Ss https://raw.githubusercontent.com/mkolakowski/curl/main/claude.sh) [command]
#
# One session per project folder, listed one per line in
# ~/.config/claude-sessions.conf:
#
#   # name      work directory                flags
#   site        /home/matt/GitHub/site         autostart yolo
#   api         /home/matt/GitHub/api          autostart yolo remote
#   scratch     /tmp/scratch                   noautostart noyolo
#
#   autostart / noautostart   enabled as a systemd unit, so it comes up on boot
#   yolo / noyolo             --dangerously-skip-permissions (default: yolo,
#                             because nobody is there to answer a prompt)
#   remote                    Remote Control server mode: claude remote-control
#   remote-interactive        claude --remote-control: reachable remotely AND
#                             usable on the box
#   local                     neither (the default)
#
# Adding a project means adding a line. Nothing else changes: one templated
# unit, claude-session@<name>.service, serves every session.
#
#   claude.sh add site ~/GitHub/site     register it
#   claude.sh sync                       make systemd agree with the config
#   tmux attach -t claude-site           watch it
#
# Run with no command for a table of what exists and what is running.
#
# This script only handles Claude Code and its sessions. For everything else
# (Docker, Tailscale, btop, ...) use curl.sh in the same repo.
#
# Config:
#   CLAUDE_SESSIONS_CONF  registry path   (default: ~/.config/claude-sessions.conf)
#   CLAUDE_CMD            launch command  (default: claude)
#   ASSUME_YES=1          never prompt; take every default

set -uo pipefail

# ---------------------------------------------------------------- constants --
readonly VERSION="4.0.2"           # keep in step with the top entry of CHANGELOG.md
readonly REPO_URL="https://github.com/mkolakowski/curl"
readonly TAB=$'\t'

# Bump when the generated runner's contract changes (arguments, config it
# reads, exit codes the unit relies on). A runner on disk declaring anything
# else cannot be trusted to start the session we ask it for.
readonly RUNNER_VERSION=1

# Every session is claude-<name> on tmux's default socket, so `tmux ls` and
# `tmux attach -t claude-<name>` work with no extra flags.
readonly SESSION_PREFIX="claude-"

# Exit code the runner uses for "this session is misconfigured". The unit maps
# it to RestartPreventExitStatus, so a bad config fails once instead of
# restarting forever.
readonly EX_CONFIG=78

# Screen-era leftovers we clean up when migrating.
readonly CRON_MARKER="# claude-session-boot (managed by claude.sh)"
readonly CRON_MARKER_LEGACY="# claude-session-boot (managed by curl.sh)"

# ------------------------------------------------------------------ plumbing --
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'
else
    C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''
fi

say()  { printf '%s\n' "${C_BLUE}::${C_RESET} $*"; }
ok()   { printf '%s\n' "  ${C_GREEN}ok${C_RESET}   $*"; }
skip() { printf '%s\n' "  ${C_DIM}skip${C_RESET} $*"; }
warn() { printf '%s\n' "  ${C_YELLOW}warn${C_RESET} $*" >&2; }
die()  { printf '%s\n' "${C_RED}error${C_RESET} $*" >&2; exit 1; }

# Read a line from the controlling terminal, so this works both as
# `bash <(curl ...)` and as `curl ... | bash`.
ask() {
    local prompt="$1" default="${2:-}" reply=''
    if [ -n "${ASSUME_YES:-}" ] || [ ! -r /dev/tty ]; then
        printf '%s\n' "$default"
        return 0
    fi
    read -r -p "$prompt" reply < /dev/tty || reply=''
    printf '%s\n' "${reply:-$default}"
}

ask_yn() {
    local prompt="$1" default="$2" reply
    reply="$(ask "$prompt [$([ "$default" = y ] && echo 'Y/n' || echo 'y/N')]: " "$default")"
    case "$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]')" in
        y|yes) return 0 ;;
        n|no)  return 1 ;;
        *)     [ "$default" = y ] ;;
    esac
}

have() { command -v "$1" >/dev/null 2>&1; }

# Printed once per run so it is obvious which version is on the box — these are
# curled straight off main, so "which one am I running" is a fair question.
banner() { printf '%s\n' "${C_DIM}claude.sh $VERSION${C_RESET}"; }

VERBOSE="${CLAUDE_SH_VERBOSE:-}"
vlog() { [ -n "$VERBOSE" ] || return 0; printf '%s\n' "${C_DIM}[$(date +%H:%M:%S)] $*${C_RESET}" >&2; }

# ---------------------------------------------------------- user / privilege --
# $SUDO_USER is only meaningful when we are actually root: it then names the
# human who ran `sudo`. In a non-root shell it may be a leftover from some
# earlier sudo in the ancestry, so it must not be trusted there.
if [ "$(id -u)" -eq 0 ]; then
    SUDO=''
    TARGET_USER="${SUDO_USER:-root}"
else
    SUDO='sudo'
    TARGET_USER="$(id -un)"
fi

TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)"
[ -n "$TARGET_HOME" ] || TARGET_HOME="$HOME"

# Run a command as the human who invoked us (not as root), with a login shell
# so ~/.local/bin ends up on PATH.
as_user() {
    if [ "$(id -un)" = "$TARGET_USER" ]; then
        bash -lc "$*"
    elif have sudo; then
        # Note: NOT "$SUDO -u", which expands to a bare "-u ..." when we are
        # already root and $SUDO is empty. Root needs no password for this.
        sudo -u "$TARGET_USER" -H bash -lc "$*"
    elif have runuser; then
        runuser -l "$TARGET_USER" -c "$*"
    else
        su - "$TARGET_USER" -c "$*"
    fi
}

# Run something as the target user with a hard ceiling, for probes that must
# never be able to wedge the script. Long operations (clone, install) use plain
# as_user instead.
as_user_t() {
    local secs="$1"; shift
    local t0 rc
    t0=$(date +%s)
    vlog "as_user(${secs}s): $*"
    timeout "$secs" bash -c "$(declare -f as_user have); TARGET_USER=$(printf %q "$TARGET_USER"); SUDO=$(printf %q "$SUDO"); as_user $(printf %q "$*")"
    rc=$?
    vlog "  -> rc=$rc after $(( $(date +%s) - t0 ))s"
    [ "$rc" = 124 ] && vlog "  !! timed out after ${secs}s"
    return $rc
}

# Anything we create in $TARGET_HOME while running under sudo must not stay
# root-owned, or the session (and Claude Code) can't write to it later.
own() { [ -e "$1" ] && $SUDO chown -R "$TARGET_USER" "$1" 2>/dev/null; return 0; }

# mkdir as the target user. Creating ~/.local/bin as root also creates ~/.local
# as root, and chowning only the leaf leaves the parent unwritable — which is
# how the Claude Code installer ends up failing with EACCES on ~/.local/share.
mkdir_for_user() {
    as_user "mkdir -p $(printf %q "$1")" 2>/dev/null && return 0
    mkdir -p "$1" && own "$1"
}

ensure_home_dirs() {
    local d
    for d in "$TARGET_HOME/.config" "$TARGET_HOME/.local/bin" \
             "$TARGET_HOME/.local/share" "$TARGET_HOME/.local/state" "$SESSION_LOG_DIR"; do
        mkdir_for_user "$d"
    done
    own "$TARGET_HOME/.config"
    own "$TARGET_HOME/.local"
}

require_sudo() {
    [ -z "$SUDO" ] && return 0
    have sudo || die "sudo is not installed and we are not root."
    # `sudo -v` prompts for a password even where NOPASSWD applies, which fails
    # outright when there is no tty. Probe non-interactively first: if that
    # succeeds we are either NOPASSWD or already authenticated.
    sudo -n true 2>/dev/null && return 0
    sudo -v || die "sudo authentication failed."
}

# -------------------------------------------------------------------- config --
SESSIONS_CONF="${CLAUDE_SESSIONS_CONF:-$TARGET_HOME/.config/claude-sessions.conf}"
RUNNER="$TARGET_HOME/.local/bin/claude-session-run.sh"
SESSION_LOG_DIR="$TARGET_HOME/.local/state/claude-sessions"
ENV_FILE="$TARGET_HOME/.config/claude-sessions.env"
ENV_FILE_SYSTEM="/etc/claude-sessions.env"
UNIT_NAME="claude-session@.service"
UNIT_PATH="/etc/systemd/system/$UNIT_NAME"

# Screen-era paths, kept only so migration can find and retire them.
LEGACY_CONF="$TARGET_HOME/.config/claude-session.env"
LEGACY_BOOT="$TARGET_HOME/.local/bin/claude-session-boot.sh"
LEGACY_BOOT_LOG="$TARGET_HOME/.local/state/claude-session-boot.log"

CLAUDE_CMD="${CLAUDE_CMD:-claude}"

# -------------------------------------------------------------- the registry --
# One session per line:  <name>  <work-dir>  [flags...]
# Flags are order-independent. Anything after # is a comment. Work directories
# may not contain spaces.
# sessions_read emits: name<TAB>dir<TAB>auto(yes|no)<TAB>remote(no|server|interactive)<TAB>yolo(yes|no)
sessions_read() {
    [ -r "$SESSIONS_CONF" ] || return 0
    awk -v home="$TARGET_HOME" '{ sub(/#.*/, "") }
         NF >= 2 {
             auto = "yes"; remote = "no"; yolo = "yes"
             for (i = 3; i <= NF; i++) {
                 if      ($i == "noautostart")        auto   = "no"
                 else if ($i == "autostart")          auto   = "yes"
                 else if ($i == "remote")             remote = "server"
                 else if ($i == "remote-interactive") remote = "interactive"
                 else if ($i == "local")              remote = "no"
                 else if ($i == "noyolo")             yolo   = "no"
                 else if ($i == "yolo")               yolo   = "yes"
             }
             dir = $2
             if (dir == "~")            dir = home
             else if (dir ~ /^~\//)     dir = home substr(dir, 2)
             print $1 "\t" dir "\t" auto "\t" remote "\t" yolo
         }' "$SESSIONS_CONF"
}

session_names()   { sessions_read | cut -f1; }
session_count()   { sessions_read | grep -c . ; }
session_field()   { sessions_read | awk -F'\t' -v n="$1" -v f="$2" '$1 == n { print $f; exit }'; }
session_dir()     { session_field "$1" 2; }
session_auto()    { session_field "$1" 3; }
session_remote()  { session_field "$1" 4; }
session_yolo()    { session_field "$1" 5; }
session_known()   { [ -n "$(session_field "$1" 1)" ]; }
autostart_names() { sessions_read | awk -F'\t' '$3 == "yes" { print $1 }'; }

sessions_header() {
    printf '%s\n' \
        '# Claude Code sessions, one per line. Managed by claude.sh, safe to edit.' \
        '# Run "claude.sh sync" after editing so systemd matches what is here.' \
        '#' \
        '#   <name>  <work directory>  [flags...]' \
        '#' \
        '# autostart           enabled as a systemd unit, so it starts on boot (default)' \
        '# yolo                --dangerously-skip-permissions, because nothing can' \
        '#                     answer a permission prompt in an unattended session' \
        '#                     (the default; say noyolo to opt a folder out)' \
        '# remote              Remote Control server mode: claude remote-control.' \
        '#                     Drive it from claude.ai/code or the Claude app. There' \
        '#                     is no local prompt; the pane shows connection status.' \
        '# remote-interactive  a normal session that is ALSO reachable remotely:' \
        '#                     claude --remote-control. You can type on the box too.' \
        '#' \
        '# Work directories may not contain spaces. ~ is expanded.' \
        ''
}

# Render one registry row. Columns are separated by real spaces as well as
# padded, so a name or path longer than its column cannot run into the next one.
session_row() {
    local name="$1" dir="$2" auto="$3" remote="$4" yolo="$5" flags
    flags="$auto"
    [ "$yolo" = noyolo ] && flags="$flags noyolo"
    [ -n "$remote" ] && flags="$flags $remote"
    printf '%-12s %-34s %s\n' "$name" "$dir" "$flags"
}

# Turn parsed fields back into the words the file uses.
flag_auto()   { [ "$1" = no ] && printf 'noautostart' || printf 'autostart'; }
flag_yolo()   { [ "$1" = no ] && printf 'noyolo'      || printf 'yolo'; }
flag_remote() {
    case "$1" in
        server)      printf 'remote' ;;
        interactive) printf 'remote-interactive' ;;
        *)           printf '' ;;
    esac
}

sessions_write() {
    local tmp; tmp="$(mktemp)"
    cat > "$tmp"
    mkdir_for_user "$(dirname "$SESSIONS_CONF")"
    install -m 0644 "$tmp" "$SESSIONS_CONF"
    rm -f "$tmp"
    own "$SESSIONS_CONF"
}

# Rewrite the registry from parsed rows, with $1 excluded (may be empty).
sessions_rewrite_without() {
    local drop="${1:-}" n d a r y
    { sessions_header
      while IFS="$TAB" read -r n d a r y; do
          [ -n "$n" ] || continue
          [ "$n" = "$drop" ] && continue
          session_row "$n" "$d" "$(flag_auto "$a")" "$(flag_remote "$r")" "$(flag_yolo "$y")"
      done < <(sessions_read)
    }
}

session_add() {
    local name="$1" dir="$2" auto="${3:-autostart}" remote="${4:-}" yolo="${5:-yolo}"
    case "$name" in
        *[!A-Za-z0-9._-]*|'') die "session name '$name' may only contain letters, digits, dot, dash and underscore." ;;
    esac
    case "$dir" in *[[:space:]]*|'') die "work directory '$dir' may not contain spaces." ;; esac
    dir="${dir/#\~/$TARGET_HOME}"

    local n d a r y wrote=0
    # Replace in place when the name already exists, so toggling a flag does not
    # shuffle a session to the bottom and renumber the menu underneath you.
    { sessions_header
      while IFS="$TAB" read -r n d a r y; do
          [ -n "$n" ] || continue
          if [ "$n" = "$name" ]; then
              session_row "$name" "$dir" "$auto" "$remote" "$yolo"; wrote=1
          else
              session_row "$n" "$d" "$(flag_auto "$a")" "$(flag_remote "$r")" "$(flag_yolo "$y")"
          fi
      done < <(sessions_read)
      [ "$wrote" = 1 ] || session_row "$name" "$dir" "$auto" "$remote" "$yolo"
    } | sessions_write

    mkdir_for_user "$dir"
    ok "registered '$name' -> $dir ($auto, $yolo${remote:+, $remote})"
    return 0
}

session_remove() {
    local name="$1"
    session_known "$name" || { skip "no session named '$name' in the registry"; return 0; }
    stop_one "$name" >/dev/null 2>&1 || true
    unit_disable "$name"
    sessions_rewrite_without "$name" | sessions_write
    ok "removed '$name' from the registry and disabled its unit"
}

# Change one flag without disturbing the others.
session_set_flag() {
    local name="$1" which="$2" val="$3" auto rem yolo
    session_known "$name" || die "no session named '$name'. See: claude.sh list"
    auto="$(flag_auto   "$(session_auto   "$name")")"
    rem="$(flag_remote  "$(session_remote "$name")")"
    yolo="$(flag_yolo   "$(session_yolo   "$name")")"
    case "$which" in
        remote)
            case "$val" in
                on|server)    rem=remote ;;
                interactive)  rem='remote-interactive' ;;
                off|no|local) rem='' ;;
                *) die "usage: claude.sh remote <name> on|interactive|off" ;;
            esac ;;
        yolo)
            case "$val" in
                on|yes)  yolo=yolo ;;
                off|no)  yolo=noyolo ;;
                *) die "usage: claude.sh yolo <name> on|off" ;;
            esac ;;
        autostart)
            case "$val" in
                on|yes)  auto=autostart ;;
                off|no)  auto=noautostart ;;
                *) die "usage: claude.sh autostart <name> on|off" ;;
            esac ;;
    esac
    session_add "$name" "$(session_dir "$name")" "$auto" "$rem" "$yolo"
    unit_sync_one "$name"
    if session_running "$name"; then
        warn "'$name' is running — restart it for this to take effect: claude.sh restart $name"
    fi
}

# An older single-session install left WORK_DIR/SESSION_NAME in a shell-style
# file. Fold it into the registry once, so upgrading keeps your session.
migrate_legacy_config() {
    [ -r "$SESSIONS_CONF" ] && return 0
    [ -r "$LEGACY_CONF" ]   || return 0
    local wd sn
    wd="$(awk -F= '/^WORK_DIR=/     { print $2 }' "$LEGACY_CONF" | tail -1)"
    sn="$(awk -F= '/^SESSION_NAME=/ { print $2 }' "$LEGACY_CONF" | tail -1)"
    [ -n "$wd" ] || return 0
    [ -n "$sn" ] || sn=claude
    { sessions_header; session_row "$sn" "$wd" autostart '' yolo; } | sessions_write
    ok "migrated $LEGACY_CONF into $SESSIONS_CONF ('$sn' -> $wd)"
}

# -------------------------------------------------------------- tmux sessions --
# Everything runs on tmux's DEFAULT socket under $TARGET_USER, so the sessions
# show up in a plain `tmux ls` and attach with a plain `tmux attach -t
# claude-<name>`. That does mean one tmux server hosts them all: the unit uses
# KillMode=process and an explicit ExecStop so stopping one session never takes
# the server (and everyone else's sessions) down with it.
tmux_as_user() {
    if [ "$(id -un)" = "$TARGET_USER" ]; then
        tmux "$@"
    elif have sudo; then
        sudo -u "$TARGET_USER" -H tmux "$@"
    else
        su - "$TARGET_USER" -c "tmux $(printf '%q ' "$@")"
    fi
}

tmux_name() { printf '%s%s' "$SESSION_PREFIX" "$1"; }

# "=name" makes tmux match the name exactly. Without it, has-session does a
# prefix/fnmatch and "claude-api" would happily answer for "claude-api2".
session_running() {
    have tmux || return 1
    tmux_as_user has-session -t "=$(tmux_name "$1")" 2>/dev/null
}

running_names() {
    have tmux || return 0
    tmux_as_user list-sessions -F '#{session_name}' 2>/dev/null \
        | sed -n "s/^${SESSION_PREFIX}//p"
}

# NOTE the trailing colon. capture-pane and pipe-pane take a PANE target, and
# "=name" is session syntax — they fail with "can't find pane" on it, and
# silently so once stderr is discarded. "=name:" means "the current pane of
# exactly this session", which is what we actually want.
session_pane_dump() {
    local name="$1" out
    out="$(tmux_as_user capture-pane -p -t "=$(tmux_name "$name"):" 2>/dev/null | sed '/^[[:space:]]*$/d')"
    # A session that has already gone still leaves its last screen on disk.
    if [ -z "$out" ] && [ -s "$(session_screen_of "$name")" ]; then
        out="$(sed '/^[[:space:]]*$/d' "$(session_screen_of "$name")")"
    fi
    printf '%s\n' "$out"
}

# ------------------------------------------------------------ systemd wiring --
have_systemd() { have systemctl && [ -d /run/systemd/system ]; }

unit_of() { printf 'claude-session@%s.service' "$1"; }

# Unprivileged reads, so list/status stay usable without sudo.
unit_state() {
    have_systemd || { printf 'n/a'; return 0; }
    systemctl is-active "$(unit_of "$1")" 2>/dev/null || true
}
unit_enabled() {
    have_systemd || return 1
    [ "$(systemctl is-enabled "$(unit_of "$1")" 2>/dev/null)" = enabled ]
}
unit_failed() {
    have_systemd || return 1
    [ "$(systemctl is-active "$(unit_of "$1")" 2>/dev/null)" = failed ]
}

unit_enable() {
    have_systemd || return 1
    $SUDO systemctl enable "$(unit_of "$1")" >/dev/null 2>&1
}
unit_disable() {
    have_systemd || return 1
    $SUDO systemctl disable "$(unit_of "$1")" >/dev/null 2>&1
}

# Make one session's unit enablement match its autostart flag.
unit_sync_one() {
    local name="$1"
    have_systemd || return 0
    [ -r "$UNIT_PATH" ] || return 0
    if [ "$(session_auto "$name")" = yes ]; then
        unit_enabled "$name" || { unit_enable "$name" && ok "enabled $(unit_of "$name")"; }
    else
        unit_enabled "$name" && { unit_disable "$name" && ok "disabled $(unit_of "$name")"; }
    fi
    return 0
}

# Every unit we have ever enabled, whether or not it is still in the config.
enabled_unit_names() {
    have_systemd || return 0
    local f b
    for f in /etc/systemd/system/multi-user.target.wants/claude-session@*.service; do
        [ -e "$f" ] || continue          # no matches: the glob stays literal
        b="${f##*/}"; b="${b#claude-session@}"
        printf '%s\n' "${b%.service}"
    done
}

# The whole point of the templated unit: the config is the source of truth, and
# sync makes systemd agree with it. Adding a project is a line in a file plus
# this; it never means editing a unit.
sync_units() {
    have_systemd || { warn "no systemd here — nothing to sync"; return 1; }
    [ -r "$UNIT_PATH" ] || { warn "$UNIT_PATH is missing — run: claude.sh install"; return 1; }
    require_sudo
    say "Making systemd match $SESSIONS_CONF"
    local n changed=0
    for n in $(session_names); do
        if [ "$(session_auto "$n")" = yes ]; then
            if unit_enabled "$n"; then skip "$n already enabled"
            else unit_enable "$n" && { ok "enabled $(unit_of "$n")"; changed=1; }; fi
        else
            if unit_enabled "$n"; then unit_disable "$n" && { ok "disabled $(unit_of "$n")"; changed=1; }
            else skip "$n stays disabled (noautostart)"; fi
        fi
    done
    # Units enabled for sessions that are no longer registered would come back
    # on the next boot and fail, so retire them here.
    for n in $(enabled_unit_names); do
        session_known "$n" && continue
        $SUDO systemctl disable --now "$(unit_of "$n")" >/dev/null 2>&1
        warn "disabled $(unit_of "$n") — '$n' is no longer in the registry"
        changed=1
    done
    [ "$changed" = 0 ] && skip "already in sync"
    return 0
}

# ------------------------------------------------------- start / stop / enter --
# With systemd we go through the unit, so Restart=always owns the session's
# lifetime. Without it (a container, WSL without systemd) we start the tmux
# session directly and there is no supervision — status says so.
start_one() {
    local name="$1" dir
    dir="$(session_dir "$name")"
    [ -n "$dir" ] || { warn "'$name' is not registered — add it with: claude.sh add $name <dir>"; return 1; }
    if session_running "$name"; then skip "'$name' already running"; return 0; fi

    ensure_runner || return 1

    local mode yolo
    mode="$(session_remote "$name")"
    yolo="$(session_yolo "$name")"
    case "$mode" in
        server)      say "Starting '$name' in $dir ${C_CYAN}(remote control, server mode)${C_RESET}" ;;
        interactive) say "Starting '$name' in $dir ${C_CYAN}(remote control, interactive)${C_RESET}" ;;
        *)           say "Starting '$name' in $dir" ;;
    esac
    [ "$yolo" = no ] && warn "'$name' is noyolo — it will stop at the first permission prompt"

    if have_systemd && [ -r "$UNIT_PATH" ]; then
        require_sudo
        vlog "systemctl start $(unit_of "$name")"
        if ! $SUDO systemctl start "$(unit_of "$name")" 2>&1 | sed 's/^/         /'; then
            warn "systemctl start failed for $(unit_of "$name")"
        fi
    else
        vlog "no systemd — running the runner detached"
        as_user "CLAUDE_CMD=$(printf %q "$CLAUDE_CMD") $(printf %q "$RUNNER") --detach $(printf %q "$name")" 2>&1 \
            | sed 's/^/         /'
    fi

    # Give the runner a moment to create the tmux session before judging it.
    local i
    for i in 1 2 3 4 5 6 7 8; do
        session_running "$name" && break
        sleep 1
    done

    if session_running "$name"; then
        ok "'$name' is up ${C_DIM}(tmux attach -t $(tmux_name "$name"))${C_RESET}"
        [ "$mode" != no ] && verify_remote "$name"
        return 0
    fi

    warn "'$name' did not come up"
    show_failure "$name"
    return 1
}

# One place that answers "why didn't it start", whichever way it was started.
show_failure() {
    local name="$1" log
    if have_systemd && [ -r "$UNIT_PATH" ]; then
        if unit_failed "$name"; then
            warn "  the unit is in the failed state:"
            $SUDO systemctl status "$(unit_of "$name")" --no-pager -n 8 2>/dev/null \
                | sed 's/^/         /' >&2
        fi
        warn "  journal: journalctl -u $(unit_of "$name") -n 40"
    fi
    log="$(session_log_of "$name")"
    if [ -s "$log" ]; then
        warn "  the session printed this before exiting:"
        tail -12 "$log" | sed 's/\r$//' | sed '/^[[:space:]]*$/d' | sed 's/^/         /' >&2
    fi
}

stop_one() {
    local name="$1"
    local was_running=0
    session_running "$name" && was_running=1

    if have_systemd && [ -r "$UNIT_PATH" ] && [ "$(unit_state "$name")" != inactive ]; then
        require_sudo
        $SUDO systemctl stop "$(unit_of "$name")" >/dev/null 2>&1
    fi
    # Belt and braces: the unit's ExecStop kills the tmux session, but a session
    # started by hand (or before systemd was set up) has no unit behind it.
    session_running "$name" && tmux_as_user kill-session -t "=$(tmux_name "$name")" >/dev/null 2>&1

    sleep 1
    if session_running "$name"; then warn "'$name' would not die"; return 1; fi
    if [ "$was_running" = 1 ]; then ok "'$name' stopped"; else skip "'$name' is not running"; fi
    return 0
}

restart_one() {
    local name="$1"
    if have_systemd && [ -r "$UNIT_PATH" ] && session_known "$name"; then
        require_sudo
        say "Restarting '$name'"
        $SUDO systemctl restart "$(unit_of "$name")" >/dev/null 2>&1
        local i
        for i in 1 2 3 4 5 6 7 8; do session_running "$name" && break; sleep 1; done
        if session_running "$name"; then ok "'$name' is up"; return 0; fi
        warn "'$name' did not come back"; show_failure "$name"; return 1
    fi
    stop_one "$name"; start_one "$name"
}

enter_one() {
    local name="$1" sess
    sess="$(tmux_name "$name")"
    session_running "$name" || die "'$name' is not running."
    [ -t 0 ] || die "not a terminal — attach by hand with: tmux attach -t $sess"
    say "Attaching to '$name' — detach again with ${C_BOLD}Ctrl-b d${C_RESET}"
    if [ "$(id -un)" = "$TARGET_USER" ]; then
        exec tmux attach -t "=$sess"
    elif have sudo; then
        exec sudo -u "$TARGET_USER" -H tmux attach -t "=$sess"
    else
        exec su - "$TARGET_USER" -c "tmux attach -t $(printf %q "=$sess")"
    fi
}

# for_each <action> [name...] — no names means every registered session.
for_each() {
    local action="$1"; shift
    local names="$*" n rc=0
    [ -n "${names// /}" ] || names="$(session_names)"
    [ -n "${names// /}" ] || { warn "no sessions registered — add one with: claude.sh add <name> <dir>"; return 1; }
    for n in $names; do "$action" "$n" || rc=1; done
    return $rc
}

# --------------------------------------------------------------- remote control --
# Why Remote Control would refuse, as a list of reasons. Empty output means the
# preconditions look right. This exists because `claude --remote-control` does
# NOT fail when it cannot connect: it quietly starts an ordinary session and
# shows a notification you never see from a detached tmux pane.
remote_blockers() {
    local probe api token base bedrock vertex claude_bin
    vlog "probing the session environment"
    # One login shell, not six: each as_user is a full `sudo bash -lc`, and on a
    # slow box six of them back to back looks exactly like a hang.
    # shellcheck disable=SC2016  # expanded in the session's own login shell
    probe="$(as_user_t 20 'printf "%s\n" "claude=$(command -v claude 2>/dev/null)" "api=${ANTHROPIC_API_KEY:-}" "token=${CLAUDE_CODE_OAUTH_TOKEN:-}" "base=${ANTHROPIC_BASE_URL:-}" "bedrock=${CLAUDE_CODE_USE_BEDROCK:-}" "vertex=${CLAUDE_CODE_USE_VERTEX:-}"')"
    claude_bin="$(printf '%s\n' "$probe" | sed -n 's/^claude=//p')"
    api="$(printf '%s\n'    "$probe" | sed -n 's/^api=//p')"
    token="$(printf '%s\n'  "$probe" | sed -n 's/^token=//p')"
    base="$(printf '%s\n'   "$probe" | sed -n 's/^base=//p')"
    bedrock="$(printf '%s\n' "$probe" | sed -n 's/^bedrock=//p')"
    vertex="$(printf '%s\n' "$probe" | sed -n 's/^vertex=//p')"

    if [ -z "$claude_bin" ]; then
        printf '%s\n' "Claude Code is not installed"
        return 0
    fi
    vlog "claude at $claude_bin; checking claude.ai login"
    if ! as_user_t 15 'claude auth status >/dev/null 2>&1'; then
        printf '%s\n' "not signed in to claude.ai — run: claude auth login"
    fi
    [ -n "$api" ]     && printf '%s\n' "ANTHROPIC_API_KEY is set; Remote Control needs a claude.ai login and refuses keys"
    [ -n "$token" ]   && printf '%s\n' "CLAUDE_CODE_OAUTH_TOKEN is set; Remote Control needs a full claude.ai login"
    [ -n "$base" ]    && printf '%s\n' "ANTHROPIC_BASE_URL is set ($base); Remote Control only works against api.anthropic.com"
    [ -n "$bedrock" ] && printf '%s\n' "CLAUDE_CODE_USE_BEDROCK is set; Remote Control is not available on that provider"
    [ -n "$vertex" ]  && printf '%s\n' "CLAUDE_CODE_USE_VERTEX is set; Remote Control is not available on that provider"
    return 0
}

remote_preflight() {
    local blockers
    # Name the ceiling rather than saying "a few seconds": these two probes are
    # login shells and can genuinely take half a minute on a cold box, and
    # silence for that long reads as a hang.
    say "Checking Remote Control preconditions${C_DIM} (up to 35s)${C_RESET}"
    blockers="$(remote_blockers)"
    if [ -z "$blockers" ]; then
        skip "remote control preconditions look fine"
        return 0
    fi
    warn "Remote Control will not connect:"
    printf '%s\n' "$blockers" | sed 's/^/         - /' >&2
    return 1
}

# After starting a remote session, say whether it really connected.
verify_remote() {
    local name="$1" dump
    say "Waiting for Remote Control to connect${C_DIM} (a few seconds)${C_RESET}"
    sleep 4
    dump="$(session_pane_dump "$name")"
    if printf '%s' "$dump" | grep -qi 'claude\.ai/code\|remote control session\|session url'; then
        ok "remote control is connected"
        printf '%s\n' "$dump" | grep -io 'https://claude\.ai/code[^[:space:]]*' | head -1 | sed 's/^/         /'
        return 0
    fi
    if printf '%s' "$dump" | grep -qiE 'remote control (requires|is (not|disabled))|couldn.t (verify|reconnect)|remote credentials fetch failed|trust'; then
        warn "the session started but Remote Control did not connect. It says:"
        printf '%s\n' "$dump" | grep -iE 'remote control|trust|login|subscription' | head -4 | sed 's/^/         /' >&2
        return 1
    fi
    warn "could not confirm Remote Control connected — try: claude.sh doctor $name"
    return 1
}

# ------------------------------------------------------------------ the table --
# Pad plain text first, then colourise, so escape sequences never shift columns.
tilde() { printf '%s' "${1/#$TARGET_HOME/\~}"; }

print_table() {
    local n dir auto remote yolo count=0 state pad r y b
    printf '\n  %-3s %-13s %-9s %-6s %-8s %-5s %s\n' '#' 'session' 'state' 'boot' 'remote' 'yolo' 'work directory'
    printf '  %s\n' "$(printf '%.0s-' {1..76})"
    while IFS="$TAB" read -r n dir auto remote yolo; do
        [ -n "$n" ] || continue
        count=$((count + 1))
        if session_running "$n";  then printf -v pad '%-9s' running; state="${C_GREEN}${pad}${C_RESET}"
        elif unit_failed "$n";    then printf -v pad '%-9s' failed;  state="${C_RED}${pad}${C_RESET}"
        else                           printf -v pad '%-9s' stopped; state="${C_DIM}${pad}${C_RESET}"; fi
        [ "$auto" = yes ] && b=auto || b=manual
        case "$remote" in
            server)      printf -v r '%-8s' server; r="${C_CYAN}${r}${C_RESET}" ;;
            interactive) printf -v r '%-8s' inter;  r="${C_CYAN}${r}${C_RESET}" ;;
            *)           printf -v r '%-8s' '-';    r="${C_DIM}${r}${C_RESET}" ;;
        esac
        if [ "$yolo" = yes ]; then printf -v y '%-5s' yes; y="${C_DIM}${y}${C_RESET}"
        else                       printf -v y '%-5s' 'NO'; y="${C_YELLOW}${y}${C_RESET}"; fi
        printf '  %-3s %-13s %b %-6s %b %b %s\n' "$count" "$n" "$state" "$b" "$r" "$y" "$(tilde "$dir")"
    done < <(sessions_read)
    if [ "$count" -eq 0 ]; then
        printf '  %s\n' "${C_DIM}nothing registered yet — claude.sh add <name> <dir>${C_RESET}"
    fi
    # Sessions running that nobody registered: surface them rather than hide them.
    for r in $(running_names); do
        session_known "$r" || printf '  %-3s %-13s %-9s %-6s %-8s %-5s %s\n' \
            '-' "$r" 'running' '-' '-' '-' "${C_DIM}(not registered)${C_RESET}"
    done
    printf '\n'
}

nth_session() { sessions_read | awk -F'\t' -v i="$1" 'NR == i { print $1 }'; }

# The entries depend on the session's state: offering Enter for a stopped
# session put a call to die() — which exits the whole script — under the default
# keystroke, and Start/Stop/Restart are each meaningless in one of the two
# states. Build the list from what is actually possible.
manage_one() {
    local name="$1" choice rem yolo auto running=0 i
    local -a labels=() actions=()
    rem="$(session_remote "$name")"
    yolo="$(session_yolo "$name")"
    auto="$(session_auto "$name")"
    session_running "$name" && running=1

    printf '\n%s  %s\n' "${C_BOLD}$name${C_RESET}" "${C_DIM}$(tilde "$(session_dir "$name")")${C_RESET}"
    if [ "$running" = 1 ]; then
        printf '  tmux %s · attach: tmux attach -t %s\n' "$(tmux_name "$name")" "$(tmux_name "$name")"
    else
        printf '  not running%s\n' "$(unit_failed "$name" && printf ' (unit failed)')"
    fi
    printf '  boot: %s · yolo: %s · remote control: %s\n\n' \
        "$([ "$auto" = yes ] && echo 'on (systemd)' || echo off)" \
        "$([ "$yolo" = yes ] && echo on || echo off)" \
        "$(case "$rem" in server) echo 'on (server mode)' ;; interactive) echo 'on (interactive)' ;; *) echo off ;; esac)"

    if [ "$running" = 1 ]; then
        labels+=("Enter    attach to this session");        actions+=(enter)
        labels+=("Restart  stop it and start a fresh one"); actions+=(restart)
        labels+=("Stop     stop it");                       actions+=(stop)
    else
        labels+=("Start    start it");                      actions+=(start)
    fi
    # One entry per setting, cycling, labelled with where it will land rather
    # than making you work it out.
    case "$rem" in
        no)          labels+=("Remote   off → server mode") ;;
        server)      labels+=("Remote   server mode → interactive") ;;
        interactive) labels+=("Remote   interactive → off") ;;
    esac
    actions+=(remote)
    labels+=("Yolo     $([ "$yolo" = yes ] && echo 'on → off' || echo 'off → on')"); actions+=(yolo)
    labels+=("Boot     $([ "$auto" = yes ] && echo 'on → off' || echo 'off → on')"); actions+=(autostart)
    labels+=("Logs     tail this session's output");        actions+=(logs)
    labels+=("Back");                                       actions+=(back)

    for i in "${!labels[@]}"; do printf '  %d) %s\n' "$((i + 1))" "${labels[i]}"; done
    choice="$(ask "Choice [1]: " 1)"
    printf '\n'

    local act=''
    if printf '%s' "$choice" | grep -qE '^[0-9]+$' && [ "$choice" -ge 1 ] && [ "$choice" -le ${#actions[@]} ]; then
        act="${actions[$((choice - 1))]}"
    else
        case "$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')" in
            ''|e|enter) act="${actions[0]}" ;;
            r|restart)  act=restart ;;
            s|start)    act=start ;;
            stop|kill)  act=stop ;;
            remote)     act=remote ;;
            y|yolo)     act=yolo ;;
            l|logs)     act=logs ;;
            b|back|q)   act=back ;;
            *)          warn "unrecognised choice '$choice'"; return 0 ;;
        esac
    fi

    case "$act" in
        enter)
            # It may have stopped between drawing this menu and choosing, so
            # check again rather than letting enter_one exit the script.
            if session_running "$name"; then enter_one "$name"
            else warn "'$name' is no longer running"; fi ;;
        restart) restart_one "$name" ;;
        stop)    stop_one "$name" ;;
        start)   start_one "$name" ;;
        remote)
            case "$rem" in
                no)          session_set_flag "$name" remote on ;;
                server)      session_set_flag "$name" remote interactive ;;
                interactive) session_set_flag "$name" remote off ;;
            esac ;;
        yolo)      session_set_flag "$name" yolo      "$([ "$yolo" = yes ] && echo off || echo on)" ;;
        autostart) session_set_flag "$name" autostart "$([ "$auto" = yes ] && echo off || echo on)" ;;
        logs)      show_logs "$name" ;;
        back)      return 0 ;;
    esac
}

show_logs() {
    local name="$1" log; log="$(session_log_of "$name")"
    printf '%s\n' "${C_BOLD}$log${C_RESET}"
    if [ -s "$log" ]; then
        tail -30 "$log" | sed 's/\r$//' | sed 's/^/  /'
    else
        skip "nothing captured yet"
    fi
    if have_systemd && [ -r "$UNIT_PATH" ]; then
        printf '\n  %s\n' "${C_DIM}journalctl -u $(unit_of "$name") -n 40${C_RESET}"
    fi
}

main_menu() {
    local input name
    while true; do
        print_table
        printf '  %s\n' "${C_DIM}number = manage that one · n = new session · s = start all · r = restart all${C_RESET}"
        printf '  %s\n' "${C_DIM}x = stop all · y = sync systemd with the config · q = quit${C_RESET}"
        input="$(ask "Choice: " q)"
        case "$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')" in
            q|quit|'') say "Nothing changed."; return 0 ;;
            n|new)     new_session_interactive ;;
            s|start)   printf '\n'; for_each start_one   "$(autostart_names | tr '\n' ' ')" ;;
            r|restart) printf '\n'; for_each restart_one "$(autostart_names | tr '\n' ' ')" ;;
            x|stop)    printf '\n'; for_each stop_one ;;
            y|sync)    printf '\n'; sync_units ;;
            *)
                if printf '%s' "$input" | grep -qE '^[0-9]+$'; then
                    name="$(nth_session "$input")"
                    if [ -n "$name" ]; then manage_one "$name"; else warn "no session numbered $input"; fi
                elif session_known "$input"; then
                    manage_one "$input"
                else
                    warn "unrecognised choice '$input'"
                fi ;;
        esac
    done
}

# --------------------------------------------------------- new session wizard --
# Was referenced by the menu and by `claude.sh new` but never defined, so both
# died with "new_session_interactive: command not found".
new_session_interactive() {
    local name dir base repo auto rem yolo

    name="$(ask "Session name: " '')"
    [ -n "$name" ] || { warn "no name given — nothing added"; return 0; }
    case "$name" in
        *[!A-Za-z0-9._-]*) warn "'$name' may only contain letters, digits, dot, dash and underscore"; return 0 ;;
    esac
    if session_known "$name"; then
        ask_yn "  '$name' already exists — replace it?" n || return 0
    fi

    printf '\n  %s\n' "${C_BOLD}Where should it work?${C_RESET}"
    printf '  1) %s\n' "$TARGET_HOME/GitHub/$name"
    printf '  2) %s\n' "$TARGET_HOME/work/$name"
    printf '  3) %s\n' "clone a GitHub repo into $TARGET_HOME/GitHub/"
    printf '  4) %s\n' "somewhere else (type the path)"
    case "$(ask "Choice [1]: " 1)" in
        2) dir="$TARGET_HOME/work/$name" ;;
        3)
            repo="$(ask "  owner/repo (or a full git URL): " '')"
            [ -n "$repo" ] || { warn "no repo given"; return 0; }
            case "$repo" in
                *://*|git@*) base="$(basename "$repo" .git)" ;;
                */*)         base="$(basename "$repo")"; repo="https://github.com/$repo.git" ;;
                *)           warn "'$repo' does not look like owner/repo or a URL"; return 0 ;;
            esac
            dir="$TARGET_HOME/GitHub/$base"
            if [ -d "$dir/.git" ]; then
                skip "$dir is already a clone — using it"
            else
                have git || apt_ensure git git
                say "Cloning $repo"
                mkdir_for_user "$(dirname "$dir")"
                as_user "git clone $(printf %q "$repo") $(printf %q "$dir")" 2>&1 | sed 's/^/         /' \
                    || { warn "clone failed — register it anyway and fix the folder later"; }
            fi ;;
        4) dir="$(ask "  path: " "$TARGET_HOME/$name")" ;;
        *) dir="$TARGET_HOME/GitHub/$name" ;;
    esac
    dir="${dir/#\~/$TARGET_HOME}"

    printf '\n'
    ask_yn "  Start it automatically at boot?" y && auto=autostart || auto=noautostart
    ask_yn "  Skip permission prompts (--dangerously-skip-permissions)?" y && yolo=yolo || yolo=noyolo

    printf '\n  %s\n' "${C_BOLD}Remote Control?${C_RESET}"
    printf '  1) %s\n' "no — a plain local session"
    printf '  2) %s\n' "server mode — drive it from claude.ai/code, no local prompt"
    printf '  3) %s\n' "interactive — reachable remotely and usable on the box"
    case "$(ask "Choice [1]: " 1)" in
        2) rem=remote ;;
        3) rem='remote-interactive' ;;
        *) rem='' ;;
    esac

    printf '\n'
    session_add "$name" "$dir" "$auto" "$rem" "$yolo" || return 1
    [ -n "$rem" ] && { remote_preflight || true; }
    ensure_runner
    unit_sync_one "$name"
    if ask_yn "  Start '$name' now?" y; then start_one "$name"; fi
}

# ------------------------------------------------------------- install steps --
apt_ensure() {
    local bin="$1"; shift
    if have "$bin"; then skip "$bin already installed"; return 0; fi
    say "Installing $*"
    if DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq "$@"; then
        ok "$bin installed"
    else
        warn "could not install $* via apt"; return 1
    fi
}

install_claude_code() {
    if as_user 'command -v claude >/dev/null 2>&1'; then
        skip "claude code already installed ($(as_user_t 15 'claude --version' 2>/dev/null | head -1))"
        return 0
    fi
    say "Installing Claude Code"
    as_user 'curl -fsSL https://claude.ai/install.sh | bash' \
        || { warn "Claude Code install failed"; return 1; }

    local rc="$TARGET_HOME/.profile"
    if ! grep -qs '\.local/bin' "$rc" 2>/dev/null; then
        # shellcheck disable=SC2016  # $HOME must stay literal inside .profile
        printf '\n# added by claude.sh\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$rc"
        ok "added ~/.local/bin to PATH in $rc"
    fi
    if as_user 'command -v claude >/dev/null 2>&1'; then
        ok "claude code installed"
    else
        warn "claude not on PATH yet — open a new shell, or check ~/.local/bin/claude"
    fi
}

# --------------------------------------------------------- session scaffolding --
session_log_of()    { printf '%s\n' "$SESSION_LOG_DIR/$1.log"; }
# The last screen the runner saw before the session died. pipe-pane only
# captures from the moment it attaches, so a session that dies in the first
# instant leaves nothing in the log; this is what answers "why".
session_screen_of() { printf '%s\n' "$SESSION_LOG_DIR/$1.screen"; }

runner_version_of() {
    sed -n 's/^# claude-session-run runner-version: //p' "$1" 2>/dev/null | head -1
}

# The wrapper systemd runs. Type=simple wants something that stays in the
# foreground for as long as the session should live, so this creates the tmux
# session and then blocks until it goes away — at which point the process exits
# and Restart=always brings it straight back. No Type=forking, no PIDFile, and
# nothing that has to guess whether tmux is still alive.
write_runner() {
    local dest="$RUNNER" tmp
    mkdir_for_user "$(dirname "$dest")"
    mkdir_for_user "$SESSION_LOG_DIR"
    tmp="$(mktemp)"

    cat > "$tmp" <<-'RUNNER'
	#!/bin/sh
	# claude-session-run runner-version: 1
	#
	# claude-session-run.sh — run one Claude Code session inside tmux and stay in
	# the foreground for as long as it lives.
	#
	#   claude-session-run.sh <name>             what systemd runs (blocks)
	#   claude-session-run.sh --detach <name>    create it and return (no systemd)
	#
	# Exit 78 means "this session is misconfigured". The unit maps that to
	# RestartPreventExitStatus so a bad line in the registry fails once instead of
	# restarting every five seconds forever.
	#
	# Written by claude.sh as a STUB. Everything between the EDIT markers is
	# yours. claude.sh will not overwrite this file once you have edited it; it
	# writes a .new file alongside instead.

	set -u

	EX_CONFIG=78
	DETACH=''
	if [ "${1:-}" = "--detach" ]; then DETACH=1; shift; fi
	NAME="${1:-}"

	CONF="${CLAUDE_SESSIONS_CONF:-$HOME/.config/claude-sessions.conf}"
	CLAUDE_CMD="${CLAUDE_CMD:-claude}"
	LOGDIR="${CLAUDE_SESSION_LOGDIR:-$HOME/.local/state/claude-sessions}"
	SESS="claude-$NAME"

	export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
	log() { printf '%s [%s] %s\n' "$(date -Is)" "${NAME:-?}" "$*"; }

	[ -n "$NAME" ] || { log "usage: claude-session-run.sh [--detach] <name>"; exit "$EX_CONFIG"; }
	# The registry is hand-editable, so do not trust the name to be shell-safe.
	case "$NAME" in
	    *[!A-Za-z0-9._-]*) log "session name '$NAME' has characters we will not run"; exit "$EX_CONFIG" ;;
	esac

	# ---8<--- EDIT BELOW — your own pre-launch steps (stub) ---8<---
	# Runs once per session start, before tmux. Repo or credential setup belongs
	# here. Examples:
	#
	#   cd "$HOME/GitHub/$NAME" && git pull --ff-only
	#   docker compose -f "$HOME/work/compose.yaml" up -d
	#
	# Do NOT export ANTHROPIC_API_KEY here if this session is marked remote:
	# Remote Control needs a claude.ai login and refuses to start with an API key
	# in the environment. For a key, use the EnvironmentFile the unit already
	# reads: ~/.config/claude-sessions.env
	#
	# ---8<--- EDIT ABOVE ---8<---

	command -v tmux >/dev/null 2>&1 || { log "tmux is not installed"; exit "$EX_CONFIG"; }
	[ -r "$CONF" ] || { log "no session registry at $CONF"; exit "$EX_CONFIG"; }

	row="$(awk -v want="$NAME" -v home="$HOME" '
	    { sub(/#.*/, "") }
	    NF >= 2 && $1 == want {
	        remote = "no"; yolo = "yes"
	        for (i = 3; i <= NF; i++) {
	            if      ($i == "remote")             remote = "server"
	            else if ($i == "remote-interactive") remote = "interactive"
	            else if ($i == "local")              remote = "no"
	            else if ($i == "noyolo")             yolo   = "no"
	            else if ($i == "yolo")               yolo   = "yes"
	        }
	        dir = $2
	        if (dir == "~")        dir = home
	        else if (dir ~ /^~\//) dir = home substr(dir, 2)
	        print dir "\t" remote "\t" yolo
	        exit
	    }' "$CONF")"
	[ -n "$row" ] || { log "'$NAME' is not in $CONF"; exit "$EX_CONFIG"; }

	dir="$(printf '%s' "$row"  | cut -f1)"
	remote="$(printf '%s' "$row" | cut -f2)"
	yolo="$(printf '%s' "$row" | cut -f3)"

	[ -d "$dir" ] || mkdir -p "$dir" || { log "cannot create $dir"; exit "$EX_CONFIG"; }
	mkdir -p "$LOGDIR"
	LOGFILE="$LOGDIR/$NAME.log"
	SCREENFILE="$LOGDIR/$NAME.screen"
	# Restart=always means this file is appended to forever otherwise.
	if [ -f "$LOGFILE" ] && [ "$(wc -c < "$LOGFILE" 2>/dev/null || echo 0)" -gt 5242880 ]; then
	    mv -f "$LOGFILE" "$LOGFILE.1" 2>/dev/null || true
	fi

	# --dangerously-skip-permissions is a top-level option of `claude`, so it is
	# safe to append to the plain and --remote-control forms. Server mode is a
	# SUBCOMMAND whose option set we cannot assume: passing a flag it does not
	# know would make it exit immediately, and Restart=always would turn that
	# into a five-second loop. So ask it first.
	YOLO=''
	[ "$yolo" = yes ] && YOLO='--dangerously-skip-permissions'

	case "$remote" in
	    server)
	        srv_yolo=''
	        if [ -n "$YOLO" ]; then
	            if "$CLAUDE_CMD" remote-control --help 2>&1 | grep -q -- '--dangerously-skip-permissions'; then
	                srv_yolo="$YOLO"
	            else
	                log "note: 'remote-control' does not advertise --dangerously-skip-permissions; starting without it"
	            fi
	        fi
	        launch="$CLAUDE_CMD remote-control --name $NAME $srv_yolo" ;;
	    interactive)
	        launch="$CLAUDE_CMD --remote-control $NAME $YOLO" ;;
	    *)
	        launch="$CLAUDE_CMD $YOLO" ;;
	esac

	# A pane whose command exits takes the session with it instantly, and the
	# error it died complaining about goes with it: pipe-pane has only been
	# attached for a few milliseconds by then, and there is nothing left for
	# capture-pane to read. So make the pane outlive its command by a few seconds
	# and have it say what happened. This is what turns "it just isn't running"
	# into a reason you can act on.
	PANE_CMD="$launch; __rc=\$?; printf '\n[claude-session] %s exited with status %s\n' '$NAME' \"\$__rc\"; sleep 5"

	# shellcheck disable=SC2317  # reached from the trap, which shellcheck cannot see
	kill_session() { tmux kill-session -t "=$SESS" 2>/dev/null || true; }
	trap 'log "signalled — stopping $SESS"; kill_session; exit 0' TERM INT HUP

	# "=$SESS" matches the name exactly. Without the =, tmux does a prefix match
	# and "claude-api" would answer for "claude-api2".
	if tmux has-session -t "=$SESS" 2>/dev/null; then
	    log "$SESS already exists — monitoring it"
	else
	    log "starting $SESS in $dir (remote=$remote yolo=$yolo)"
	    if ! tmux new-session -d -s "$SESS" -c "$dir" "$PANE_CMD"; then
	        log "tmux would not create $SESS"
	        exit 1
	    fi
	    # Keep the pane's output, so a session that dies still leaves the reason
	    # behind. Without this it vanishes without a trace.
	    #
	    # NOTE the trailing colon: pipe-pane wants a PANE target, and a bare
	    # "=$SESS" is SESSION syntax, which it rejects with "can't find pane" —
	    # invisibly, since we are discarding stderr. "=$SESS:" is the current
	    # pane of exactly that session.
	    tmux pipe-pane -t "=$SESS:" -o "cat >> '$LOGFILE'" 2>/dev/null || true
	    log "$SESS started"
	fi

	[ -n "$DETACH" ] && exit 0

	# pipe-pane only captures from the moment it attaches, so anything printed in
	# the first instant is lost — exactly the case where a session dies on
	# startup and you want to know why. Keep the last screen on disk as well.
	snapshot() {
	    if tmux capture-pane -p -t "=$SESS:" 2>/dev/null > "$SCREENFILE.tmp"; then
	        mv -f "$SCREENFILE.tmp" "$SCREENFILE" 2>/dev/null
	    fi
	    rm -f "$SCREENFILE.tmp" 2>/dev/null
	    return 0
	}

	# Block until the session goes away. When it does we exit 0 and systemd's
	# Restart=always starts us again, which recreates it — that is the whole
	# crash-resilience story, with no PID files and nothing to go stale.
	while tmux has-session -t "=$SESS" 2>/dev/null; do
	    snapshot
	    sleep 3 & wait $! || true
	done
	snapshot
	log "$SESS ended — exiting so systemd can bring it back"
	exit 0
	RUNNER

    # A checksum of what we last wrote, so an untouched runner can be upgraded in
    # place instead of spawning a .new file on every change, while a runner you
    # have actually edited is still never overwritten.
    local stamp="$dest.sha256"
    _sum()    { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
    _record() { _sum "$dest" > "$stamp" 2>/dev/null; own "$stamp"; }

    if [ ! -e "$dest" ]; then
        install -m 0755 "$tmp" "$dest"; rm -f "$tmp"; _record
        ok "wrote $dest"
    elif cmp -s "$tmp" "$dest"; then
        rm -f "$tmp"; [ -r "$stamp" ] || _record
        skip "$dest already current"
    elif [ -r "$stamp" ] && [ "$(_sum "$dest")" = "$(cat "$stamp" 2>/dev/null)" ]; then
        install -m 0755 "$tmp" "$dest"; rm -f "$tmp"; _record
        ok "updated $dest (it was unmodified since we wrote it)"
    elif [ "$(runner_version_of "$dest")" != "$RUNNER_VERSION" ] && grep -qs 'claude-session-run' "$dest"; then
        # One of ours, but an older contract. Keeping it "safe" would mean
        # quietly running the wrong thing, so replace it and keep a copy.
        local backup="$dest.bak" n=1
        while [ -e "$backup" ]; do backup="$dest.bak.$n"; n=$((n + 1)); done
        cp -p "$dest" "$backup" 2>/dev/null && own "$backup"
        install -m 0755 "$tmp" "$dest"; rm -f "$tmp"; _record
        warn "replaced an incompatible runner (runner-version '$(runner_version_of "$backup")', wanted $RUNNER_VERSION)"
        ok "your previous copy is at $backup"
    else
        install -m 0755 "$tmp" "$dest.new"; rm -f "$tmp"
        warn "kept your $dest — newest runner written to $dest.new"
    fi
    chmod +x "$dest" 2>/dev/null || true
    own "$(dirname "$dest")"; own "$SESSION_LOG_DIR"
}

ensure_runner() {
    if [ ! -x "$RUNNER" ]; then
        warn "runner missing at $RUNNER — writing it"
        write_runner
    elif [ "$(runner_version_of "$RUNNER")" != "$RUNNER_VERSION" ]; then
        warn "$RUNNER is from an older version — replacing it"
        write_runner
    fi
    [ -x "$RUNNER" ] || { warn "could not write $RUNNER"; return 1; }
    return 0
}

# ------------------------------------------------------------- the unit file --
# ONE templated unit for every session. claude-session@site.service and
# claude-session@api.service are the same file with %i substituted, so a new
# project is a line in the registry plus `claude.sh sync` — never a new unit.
unit_text() {
    local tmux_bin; tmux_bin="$(command -v tmux 2>/dev/null)"
    [ -n "$tmux_bin" ] || tmux_bin=/usr/bin/tmux
    cat <<UNIT
[Unit]
Description=Claude Code session %i (tmux: ${SESSION_PREFIX}%i)
Documentation=$REPO_URL
After=network-online.target
Wants=network-online.target
# A session that dies instantly would otherwise restart every RestartSec
# forever. Five failures in five minutes and the unit stops trying.
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
# claude-session-run stays in the foreground for as long as the tmux session
# lives, so Type=simple describes it honestly and Restart=always is enough on
# its own. Type=forking plus tmux cannot do this: tmux double-forks to its
# server and systemd would lose track of what it is supposed to be watching.
Type=simple
User=$TARGET_USER
WorkingDirectory=$TARGET_HOME
Environment=HOME=$TARGET_HOME
# systemd's default PATH does not include ~/.local/bin, which is where the
# Claude Code installer puts claude.
Environment=PATH=$TARGET_HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Optional, and absent by default. Put ANTHROPIC_API_KEY here if you are not
# using a claude.ai login. Leading - means "fine if it does not exist".
EnvironmentFile=-$ENV_FILE_SYSTEM
EnvironmentFile=-$ENV_FILE
ExecStart=$RUNNER %i
ExecStop=$tmux_bin kill-session -t =${SESSION_PREFIX}%i
Restart=always
RestartSec=5
# $EX_CONFIG is the runner's "this session is misconfigured". Restarting would
# not fix it, so do not.
RestartPreventExitStatus=$EX_CONFIG
# All sessions share one tmux server on the default socket, so that plain
# "tmux attach -t ${SESSION_PREFIX}<name>" works. KillMode=process means stopping
# one unit kills its own process and its own session via ExecStop, and leaves
# the server — and everyone else's sessions — alone.
KillMode=process
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target
UNIT
}

write_unit() {
    have_systemd || { warn "no systemd here — skipping the unit"; return 1; }
    require_sudo
    local tmp; tmp="$(mktemp)"
    unit_text > "$tmp"

    if [ -f "$UNIT_PATH" ] && cmp -s "$tmp" "$UNIT_PATH"; then
        skip "$UNIT_PATH already up to date"
        rm -f "$tmp"
    else
        if [ -f "$UNIT_PATH" ]; then
            $SUDO cp -p "$UNIT_PATH" "$UNIT_PATH.bak" && warn "kept your existing unit as $UNIT_PATH.bak"
        fi
        $SUDO install -m 0644 "$tmp" "$UNIT_PATH" || { rm -f "$tmp"; warn "could not write $UNIT_PATH"; return 1; }
        rm -f "$tmp"
        ok "wrote $UNIT_PATH (runs as $TARGET_USER)"
    fi
    $SUDO systemctl daemon-reload >/dev/null 2>&1
    return 0
}

# ------------------------------------------------------- migration off screen --
crontab_get() { $SUDO crontab -u "$TARGET_USER" -l 2>/dev/null; }
crontab_put() { $SUDO crontab -u "$TARGET_USER" -; }

remove_cron() {
    local current
    current="$(crontab_get)"
    if printf '%s\n' "$current" | grep -qF -e "$CRON_MARKER" -e "$CRON_MARKER_LEGACY"; then
        # Only our own lines go: an unrelated @daily backup in the same crontab
        # must survive this.
        printf '%s\n' "$current" | grep -vF "$CRON_MARKER" | grep -vF "$CRON_MARKER_LEGACY" | sed '/^$/d' | crontab_put \
            && ok "removed the @reboot crontab entry"
    else
        skip "no managed crontab entry to remove"
    fi
}

screen_sessions() {
    have screen || return 0
    if [ "$(id -un)" = "$TARGET_USER" ]; then screen -ls 2>/dev/null
    elif have sudo; then sudo -u "$TARGET_USER" -H screen -ls 2>/dev/null
    else return 0; fi | awk 'match($1, /^[0-9]+\./) { print substr($1, RSTART + RLENGTH) }'
}

screen_kill() {
    if [ "$(id -un)" = "$TARGET_USER" ]; then screen -S "$1" -X quit >/dev/null 2>&1
    elif have sudo; then sudo -u "$TARGET_USER" -H screen -S "$1" -X quit >/dev/null 2>&1
    fi
}

# Everything the screen era left behind. Safe to run more than once.
migrate_from_screen() {
    local found=0 s

    if crontab_get | grep -qF -e "$CRON_MARKER" -e "$CRON_MARKER_LEGACY"; then
        found=1
        say "Retiring the @reboot crontab entry — systemd owns boot now"
        require_sudo
        remove_cron
    fi

    if [ -e "$LEGACY_BOOT" ]; then
        found=1
        local backup="$LEGACY_BOOT.retired" n=1
        while [ -e "$backup" ]; do backup="$LEGACY_BOOT.retired.$n"; n=$((n + 1)); done
        if mv "$LEGACY_BOOT" "$backup" 2>/dev/null; then
            own "$backup"
            ok "retired the screen boot script (kept at $backup)"
            [ -e "$LEGACY_BOOT.sha256" ] && rm -f "$LEGACY_BOOT.sha256"
        else
            warn "could not move $LEGACY_BOOT out of the way"
        fi
    fi

    # Screen sessions named after registered projects are the old runner's, and
    # would otherwise sit there holding the work directory alongside the new
    # tmux one. Sessions we do not recognise are left strictly alone.
    for s in $(screen_sessions); do
        session_known "$s" || continue
        found=1
        say "Stopping the old screen session '$s'"
        screen_kill "$s"
        sleep 1
        if screen_sessions | grep -qxF "$s"; then warn "screen session '$s' would not quit"
        else ok "screen session '$s' stopped"; fi
    done

    [ -e "$LEGACY_BOOT_LOG" ] && skip "old boot log left at $LEGACY_BOOT_LOG"
    [ "$found" = 0 ] && return 0
    ok "migrated off screen + cron"
    return 0
}

# ------------------------------------------------------------------ commands --
bootstrap_first_session() {
    [ "$(session_count)" -gt 0 ] && return 0
    local dir
    dir="$(ask "Working directory for your first session [$TARGET_HOME/work]: " "$TARGET_HOME/work")"
    session_add claude "${dir/#\~/$TARGET_HOME}" autostart '' yolo
}

provision() {
    require_sudo
    ensure_home_dirs

    printf '\n%s\n\n' "${C_BOLD}Setting up Claude Code on $(hostname) for $TARGET_USER${C_RESET}"

    say "Installing what the sessions need"
    apt_ensure git git                       # git first, as everything wants it
    apt_ensure tmux tmux
    apt_ensure curl curl
    install_claude_code

    say "Setting up the sessions"
    migrate_legacy_config
    migrate_from_screen
    bootstrap_first_session
    write_runner
    write_unit

    if have_systemd; then
        sync_units
    else
        warn "no systemd on this box — sessions will start but nothing supervises them"
    fi

    printf '\n%s\n' "${C_GREEN}${C_BOLD}Ready.${C_RESET}"
    printf '  %s\n' "start everything:  claude.sh start"
    printf '  %s\n' "watch one:         tmux attach -t ${SESSION_PREFIX}<name>"
}

status() {
    printf '%s\n' "${C_BOLD}claude sessions${C_RESET}"
    print_table
    printf '  %-14s %s\n' 'registry' "$SESSIONS_CONF $([ -r "$SESSIONS_CONF" ] || echo '(missing)')"
    printf '  %-14s %s\n' 'runner'   "$(tilde "$RUNNER") $([ -x "$RUNNER" ] || echo '(missing)')"
    printf '  %-14s %s\n' 'logs'     "$(tilde "$SESSION_LOG_DIR")/<name>.log"
    if have_systemd; then
        printf '  %-14s %s\n' 'unit' "$UNIT_PATH $([ -r "$UNIT_PATH" ] || echo '(missing — run: claude.sh install)')"
        printf '  %-14s %s\n' 'enabled' "$(enabled_unit_names | tr '\n' ' ' | sed 's/ $//' || true)"
    else
        printf '  %-14s %s\n' 'unit' "${C_YELLOW}no systemd — sessions are unsupervised${C_RESET}"
    fi
    for f in "$ENV_FILE" "$ENV_FILE_SYSTEM"; do
        [ -r "$f" ] && printf '  %-14s %s\n' 'env file' "$f"
    done
    printf '  %-14s %s\n' 'claude' "$(as_user_t 15 'claude --version' 2>/dev/null | head -1 || echo 'not installed')"
    printf '  %-14s %s\n' 'tmux'   "$(tmux -V 2>/dev/null || echo 'not installed')"

    # Anything still left over from the screen era is worth saying out loud.
    if crontab_get 2>/dev/null | grep -qF -e "$CRON_MARKER" -e "$CRON_MARKER_LEGACY" || [ -e "$LEGACY_BOOT" ]; then
        warn "screen-era leftovers found — clear them with: claude.sh migrate"
    fi
    if sessions_read | awk -F'\t' '$4 != "no" { found = 1 } END { exit !found }'; then
        printf '  %-14s %s\n' 'remote' "some sessions use Remote Control — see claude.ai/code"
        [ -n "${ANTHROPIC_API_KEY:-}" ] && warn "ANTHROPIC_API_KEY is set; Remote Control will refuse it"
    fi
}

# Everything you need to see when a session is not showing up.
doctor() {
    local only="${1:-}" n dir auto remote yolo dump
    printf '%s\n\n' "${C_BOLD}claude.sh doctor${C_RESET}"

    printf '  %-22s %s\n' 'user'   "$TARGET_USER ($TARGET_HOME)"
    printf '  %-22s %s\n' 'claude' "$(as_user_t 15 'claude --version' 2>/dev/null | head -1 || echo 'not installed')"
    printf '  %-22s %s\n' 'tmux'   "$(tmux -V 2>/dev/null || echo "${C_RED}not installed${C_RESET}")"
    if have_systemd; then
        printf '  %-22s %s\n' 'systemd' "yes, unit $([ -r "$UNIT_PATH" ] && echo present || echo "${C_RED}MISSING${C_RESET}")"
    else
        printf '  %-22s %s\n' 'systemd' "${C_YELLOW}not running — nothing supervises the sessions${C_RESET}"
    fi

    # Auth is assumed to be done once, by hand. Report it; never prompt for it.
    if as_user_t 25 'claude auth status >/dev/null 2>&1'; then
        printf '  %-22s %s\n' 'claude.ai login' "${C_GREEN}signed in${C_RESET}"
    elif [ -n "$(as_user "printf '%s' \"\${ANTHROPIC_API_KEY:-}\"" 2>/dev/null)" ] \
      || grep -qs ANTHROPIC_API_KEY "$ENV_FILE" "$ENV_FILE_SYSTEM" 2>/dev/null; then
        printf '  %-22s %s\n' 'claude.ai login' "${C_YELLOW}not signed in, but an API key is available${C_RESET}"
    else
        printf '  %-22s %s\n' 'claude.ai login' "${C_RED}not signed in${C_RESET}  (run once: claude auth login)"
    fi
    local v val
    for v in ANTHROPIC_API_KEY ANTHROPIC_BASE_URL CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX; do
        val="$(as_user "printf '%s' \"\${$v:-}\"" 2>/dev/null)"
        [ -n "$val" ] && printf '  %-22s %s\n' "$v" "${C_YELLOW}set${C_RESET}  (Remote Control refuses this)"
    done

    if sessions_read | awk -F'\t' '$4 != "no" { f = 1 } END { exit !f }'; then
        printf '\n  %s\n' "${C_BOLD}Remote Control eligibility${C_RESET}"
        local blockers; blockers="$(remote_blockers)"
        if [ -z "$blockers" ]; then
            printf '    %s\n' "${C_GREEN}nothing blocking it${C_RESET}"
        else
            printf '%s\n' "$blockers" | sed "s/^/    ${C_RED}x${C_RESET} /"
        fi
    fi

    printf '\n  %s\n' "${C_BOLD}Sessions${C_RESET}"
    while IFS="$TAB" read -r n dir auto remote yolo; do
        [ -n "$n" ] || continue
        [ -z "$only" ] || [ "$only" = "$n" ] || continue
        printf '    %-13s %-11s %-9s %s\n' "$n" \
            "$([ "$remote" = no ] && echo local || echo "remote:$remote")" \
            "$(session_running "$n" && echo running || echo stopped)" \
            "$([ "$yolo" = yes ] && echo yolo || echo 'noyolo (will stall on a prompt)')"
        if have_systemd && [ -r "$UNIT_PATH" ]; then
            printf '      %s %s%s\n' 'unit:' "$(unit_state "$n")" \
                "$(unit_enabled "$n" && printf ', enabled' || printf ', not enabled')"
            if unit_failed "$n"; then
                $SUDO systemctl status "$(unit_of "$n")" --no-pager -n 6 2>/dev/null | sed 's/^/        /'
            fi
        fi
        if [ "$remote" != no ] && session_running "$n"; then
            dump="$(session_pane_dump "$n")"
            if printf '%s' "$dump" | grep -qi 'claude\.ai/code'; then
                printf '      %s %s\n' "${C_GREEN}connected${C_RESET}" "$(printf '%s' "$dump" | grep -io 'https://claude\.ai/code[^[:space:]]*' | head -1)"
            else
                printf '      %s\n' "${C_YELLOW}no session URL in the pane — last lines:${C_RESET}"
                printf '%s\n' "$dump" | tail -6 | sed 's/^/        /'
            fi
        fi
        local slog; slog="$(session_log_of "$n")"
        if [ -s "$slog" ] && ! session_running "$n"; then
            printf '      %s\n' "${C_DIM}last output before it exited ($slog):${C_RESET}"
            tail -8 "$slog" | sed 's/\r$//' | sed '/^[[:space:]]*$/d' | sed 's/^/        /'
        fi
    done < <(sessions_read)
    have_systemd && printf '\n  %s\n' "${C_DIM}journal: journalctl -u 'claude-session@*' -n 50${C_RESET}"
}

uninstall() {
    say "Removing the boot scaffolding (packages and the registry are left alone)"
    require_sudo
    local n
    for n in $(enabled_unit_names); do
        $SUDO systemctl disable --now "$(unit_of "$n")" >/dev/null 2>&1 && ok "disabled $(unit_of "$n")"
    done
    for_each stop_one
    if [ -e "$UNIT_PATH" ]; then
        $SUDO rm -f "$UNIT_PATH"
        $SUDO systemctl daemon-reload >/dev/null 2>&1
        ok "removed $UNIT_PATH"
    fi
    [ -e "$RUNNER" ] && { rm -f "$RUNNER" "$RUNNER.sha256"; ok "removed $RUNNER"; }
    warn "left $SESSIONS_CONF in place — delete it by hand if you want it gone"
}

usage() {
    cat <<-USAGE
	${C_BOLD}claude.sh${C_RESET} $VERSION — run Claude Code unattended in tmux, started by systemd

	  bash <(curl -Ss https://raw.githubusercontent.com/mkolakowski/curl/main/claude.sh) [command]

	${C_BOLD}Commands${C_RESET}
	  (none)                    table of sessions; pick one, press n for a new
	                            one, or act on all of them
	  install                   install Claude Code, the runner and the unit
	  new                       register a session, prompting for each answer
	                            (including cloning a GitHub repo to work in)
	  add <name> <dir> [flags]  register a session in one line
	                            flags: --no-autostart, --no-yolo, --remote
	  rm <name>                 unregister a session, stop it, disable its unit
	  list                      print the table and exit
	  sync                      make systemd match the registry after you have
	                            edited it by hand
	  start [name...]           start the named sessions, or every autostart one
	  stop [name...]            stop the named sessions, or all of them
	  restart [name...]         stop and start again
	  attach [name]             attach; the name may be omitted if only one runs
	  logs [name]               tail what a session has printed
	  remote <name> on|interactive|off
	                            on          server mode: claude remote-control
	                                        (no local prompt; drive it remotely)
	                            interactive claude --remote-control: a normal
	                                        session that is also reachable remotely
	  yolo <name> on|off        --dangerously-skip-permissions for that session
	  autostart <name> on|off   whether systemd starts it at boot
	  status                    table plus registry, unit and Claude Code state
	  doctor [name]             why a session is not running or not connecting
	  migrate                   clear screen-era leftovers (cron, boot script)
	  uninstall                 remove the unit and the runner
	  version                   print the version and exit
	  -v, --verbose             trace what the script is doing, with timings
	  help                      this text

	${C_BOLD}Registry${C_RESET}  $SESSIONS_CONF
	  <name>  <work directory>  [autostart|noautostart] [yolo|noyolo]
	                            [local|remote|remote-interactive]
	  Adding a project is one line plus "claude.sh sync". One templated unit,
	  claude-session@<name>.service, serves every session.

	${C_BOLD}Attaching${C_RESET}
	  tmux attach -t ${SESSION_PREFIX}<name>        detach again with Ctrl-b d
	  tmux ls                            every session on the box

	${C_BOLD}Auth${C_RESET}
	  Sessions never prompt for credentials. Sign in once by hand with
	  "claude auth login", or put ANTHROPIC_API_KEY in one of these, which the
	  unit reads if present (chmod 600 them):
	    $ENV_FILE
	    $ENV_FILE_SYSTEM
	  Remote Control needs the claude.ai login specifically; it refuses API keys.

	${C_BOLD}Environment${C_RESET}
	  CLAUDE_SESSIONS_CONF      override the registry path
	  CLAUDE_CMD                launch command (now: $CLAUDE_CMD)
	  ASSUME_YES=1              never prompt, take the defaults
	  NO_COLOR=1                plain output
	  CLAUDE_SH_VERBOSE=1       same as --verbose

	For Docker, Tailscale, btop and friends, use curl.sh in the same repo.
	  $REPO_URL
	USAGE
}

enter_default() {
    local live count
    live="$(running_names)"
    count="$(printf '%s\n' "$live" | grep -c .)"
    if [ "$count" -eq 1 ]; then
        enter_one "$live"
    elif [ "$count" -eq 0 ]; then
        die "nothing is running. Start one with: claude.sh start <name>"
    else
        warn "several sessions are running — name one:"
        printf '%s\n' "$live" | sed 's/^/    /' >&2
        exit 1
    fi
}

cmd_add() {
    [ $# -ge 2 ] || die "usage: claude.sh add <name> <dir> [--no-autostart] [--no-yolo] [--remote]"
    local name="$1" dir="$2" auto=autostart rem='' yolo=yolo f
    shift 2
    for f in "$@"; do
        case "$f" in
            --no-autostart|noautostart)   auto=noautostart ;;
            --autostart|autostart)        auto=autostart ;;
            --no-yolo|noyolo)             yolo=noyolo ;;
            --yolo|yolo)                  yolo=yolo ;;
            --remote|remote)              rem=remote ;;
            --remote-interactive|remote-interactive) rem='remote-interactive' ;;
            --local|local)                rem='' ;;
            *) die "unknown flag '$f' (want --no-autostart, --no-yolo, --remote or --remote-interactive)" ;;
        esac
    done
    session_add "$name" "$dir" "$auto" "$rem" "$yolo"
    ensure_runner
    unit_sync_one "$name"
}

main() {
    # -v / --verbose may appear anywhere; strip it before dispatch.
    local a args=()
    for a in "$@"; do
        case "$a" in
            -v|--verbose) VERBOSE=1 ;;
            *) args+=("$a") ;;
        esac
    done
    set -- ${args+"${args[@]}"}

    local cmd="${1:-}"
    case "$cmd" in
        version|--version|-V) printf '%s\n' "$VERSION"; return 0 ;;
    esac
    banner
    [ -n "$VERBOSE" ] && vlog "verbose on · user=$TARGET_USER home=$TARGET_HOME registry=$SESSIONS_CONF"
    migrate_legacy_config
    [ $# -gt 0 ] && shift
    case "$cmd" in
        ''|default)
            if [ "$(session_count)" -eq 0 ] && [ ! -x "$RUNNER" ]; then
                provision
                for_each start_one "$(autostart_names | tr '\n' ' ')"
            else
                main_menu
            fi ;;
        install|setup)  provision ;;
        add)            cmd_add "$@" ;;
        new)            new_session_interactive ;;
        rm|remove)      [ $# -ge 1 ] || die "usage: claude.sh rm <name>"; session_remove "$1" ;;
        list|ls)        print_table ;;
        sync)           sync_units ;;
        remote)
            [ $# -ge 2 ] || die "usage: claude.sh remote <name> on|interactive|off"
            session_set_flag "$1" remote "$2" ;;
        yolo)
            [ $# -ge 2 ] || die "usage: claude.sh yolo <name> on|off"
            session_set_flag "$1" yolo "$2" ;;
        autostart)
            [ $# -ge 2 ] || die "usage: claude.sh autostart <name> on|off"
            session_set_flag "$1" autostart "$2" ;;
        start|boot)     if [ $# -gt 0 ]; then for_each start_one "$@"; else for_each start_one "$(autostart_names | tr '\n' ' ')"; fi ;;
        stop|kill)      for_each stop_one "$@" ;;
        restart)        if [ $# -gt 0 ]; then for_each restart_one "$@"; else for_each restart_one "$(autostart_names | tr '\n' ' ')"; fi ;;
        enter|attach)   if [ $# -gt 0 ]; then enter_one "$1"; else enter_default; fi ;;
        logs|log)       if [ $# -gt 0 ]; then show_logs "$1"; else for_each show_logs; fi ;;
        status|st)      status ;;
        doctor|diag)    doctor "${1:-}" ;;
        migrate)        migrate_from_screen ;;
        uninstall)      uninstall ;;
        help|-h|--help) usage ;;
        *)
            if session_known "$cmd"; then manage_one "$cmd"; else usage; die "unknown command '$cmd'."; fi ;;
    esac
}

main "$@"
