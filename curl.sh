#!/usr/bin/env bash
#
# curl.sh — set up an Ubuntu box: packages, container stacks, and Claude Code
# sessions running unattended in tmux under systemd.
#
#   bash <(curl -Ss https://raw.githubusercontent.com/mkolakowski/curl/main/curl.sh)
#
# With no arguments you get a menu of the three, each of which opens its own
# submenu. Or name what you want directly:
#
#   bash <(curl -Ss .../curl.sh) install git docker
#   bash <(curl -Ss .../curl.sh) containers start dockge
#   bash <(curl -Ss .../curl.sh) session add site ~/GitHub/site
#
# Every install is idempotent — anything already present is reported and
# skipped, so re-running is cheap and safe.
#
# The session half of this was a second script, claude.sh, until 4.1.0, and that
# URL kept forwarding here until 10.0.0. Everything it did is a subcommand now:
# "claude.sh list" is "curl.sh session list".

set -uo pipefail

# ---------------------------------------------------------------- constants --
readonly VERSION="10.0.0"         # keep in step with the top entry of CHANGELOG.md
readonly SCRIPT_NAME="curl.sh"
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

# Screen-era leftovers we clean up when migrating. Both spellings are matched
# against crontabs that already exist on a box, so neither string can be
# reworded — claude.sh wrote the first one back when it was its own script.
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

# Read ONE keypress from the controlling terminal — no Enter. For menus where
# every choice is a single character; anything taking a number, a list or a name
# still needs ask(), which reads a line.
#
# Prints the key lowercased. Enter comes back empty. Reads and writes /dev/tty
# directly for the same reason ask() does: stdin may be the script itself.
ask_key() {
    local prompt="$1" key=''
    if [ -n "${ASSUME_YES:-}" ] || [ ! -r /dev/tty ]; then
        printf '\n'
        return 0
    fi
    printf '%s' "$prompt" > /dev/tty
    # -s, then echo it back ourselves: without that the screen redraws with no
    # record of what was pressed.
    if ! IFS= read -rsn1 key < /dev/tty; then
        # EOF or a closed terminal. Returning empty would refresh forever, so
        # ask to leave instead.
        printf '\n' > /dev/tty
        printf 'q'
        return 0
    fi
    # Arrow and function keys arrive as ESC plus two or more bytes. Swallow the
    # rest rather than acting on them as further keystrokes.
    if [ "$key" = $'\033' ]; then
        read -rsn2 -t 0.1 _ < /dev/tty 2>/dev/null || true
        key=''
    fi
    printf '%s\n' "$key" > /dev/tty
    # Anything typed fast behind the key — someone spelling out "docker" — would
    # otherwise be read by whichever submenu opens next. Drop it.
    read -rsn64 -t 0.01 _ < /dev/tty 2>/dev/null || true
    printf '%s' "$key" | tr '[:upper:]' '[:lower:]'
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

have()         { command -v "$1" >/dev/null 2>&1; }
have_systemd() { have systemctl && [ -d /run/systemd/system ]; }
# Printed once per run so it is obvious which version is on the box — these are
# curled straight off main, so "which one am I running" is a fair question.
banner() { printf '%s\n' "${C_DIM}$SCRIPT_NAME $VERSION${C_RESET}"; }

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

# getent answers this whenever there is a passwd entry at all. The fallbacks
# only matter when there is not: $HOME is right when we are that user, and a
# guess otherwise — note that root's home is /root, not /home/root.
TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)"
if [ -z "$TARGET_HOME" ]; then
    if   [ "$TARGET_USER" = "$(id -un)" ]; then TARGET_HOME="$HOME"
    elif [ "$TARGET_USER" = root ];        then TARGET_HOME=/root
    else                                        TARGET_HOME="/home/$TARGET_USER"
    fi
fi

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

# require_sudo [what it is for] — take the reason, and print it only when we
# are actually about to interrupt somebody for a password. Being asked for a
# password with no explanation, by a script curled off the internet, is a fair
# thing to be annoyed by.
require_sudo() {
    [ -z "$SUDO" ] && return 0
    have sudo || die "sudo is not installed and we are not root."
    # `sudo -v` prompts for a password even where NOPASSWD applies, which fails
    # outright when there is no tty. Probe non-interactively first: if that
    # succeeds we are either NOPASSWD or already authenticated.
    sudo -n true 2>/dev/null && return 0
    [ -n "${1:-}" ] && say "sudo is needed to $1"
    sudo -v || die "sudo authentication failed."
}

# apt_ensure <binary> <package> [package...]
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

# ============================================================ claude sessions ==
# Everything from here to "end claude sessions" was claude.sh, a second script
# that is now gone. It is reached as "curl.sh session <command>".

VERBOSE="${CLAUDE_SH_VERBOSE:-}"
vlog() { [ -n "$VERBOSE" ] || return 0; printf '%s\n' "${C_DIM}[$(date +%H:%M:%S)] $*${C_RESET}" >&2; }

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
#
# In the ordinary case — you, running this as yourself — the files are already
# yours and chown is a no-op that does not need root. Going through $SUDO
# unconditionally meant every registry write asked for a password, so toggling
# yolo on one session prompted for one. Try it as ourselves and escalate only
# if that genuinely fails.
own() {
    [ -e "$1" ] || return 0
    chown -R "$TARGET_USER" "$1" 2>/dev/null && return 0
    [ -n "$SUDO" ] && $SUDO chown -R "$TARGET_USER" "$1" 2>/dev/null
    return 0
}

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
        '# Claude Code sessions, one per line. Managed by curl.sh, safe to edit.' \
        '# Run "curl.sh session sync" after editing so systemd matches what is here.' \
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
    session_known "$name" || die "no session named '$name'. See: curl.sh session list"
    auto="$(flag_auto   "$(session_auto   "$name")")"
    rem="$(flag_remote  "$(session_remote "$name")")"
    yolo="$(flag_yolo   "$(session_yolo   "$name")")"
    case "$which" in
        remote)
            case "$val" in
                on|server)    rem=remote ;;
                interactive)  rem='remote-interactive' ;;
                off|no|local) rem='' ;;
                *) die "usage: curl.sh session remote <name> on|interactive|off" ;;
            esac ;;
        yolo)
            case "$val" in
                on|yes)  yolo=yolo ;;
                off|no)  yolo=noyolo ;;
                *) die "usage: curl.sh session yolo <name> on|off" ;;
            esac ;;
        autostart)
            case "$val" in
                on|yes)  auto=autostart ;;
                off|no)  auto=noautostart ;;
                *) die "usage: curl.sh session autostart <name> on|off" ;;
            esac ;;
    esac
    session_add "$name" "$(session_dir "$name")" "$auto" "$rem" "$yolo"
    unit_sync_one "$name"
    if session_running "$name"; then
        warn "'$name' is running — restart it for this to take effect: curl.sh session restart $name"
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
    # Only escalate when enablement actually has to change. Toggling yolo or
    # remote control comes through here too, and neither of those touches
    # systemd at all.
    if [ "$(session_auto "$name")" = yes ]; then
        unit_enabled "$name" || {
            require_sudo "enable $(unit_of "$name")"
            unit_enable "$name" && ok "enabled $(unit_of "$name")"
        }
    else
        unit_enabled "$name" && {
            require_sudo "disable $(unit_of "$name")"
            unit_disable "$name" && ok "disabled $(unit_of "$name")"
        }
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
    [ -r "$UNIT_PATH" ] || { warn "$UNIT_PATH is missing — run: curl.sh session install"; return 1; }
    # No require_sudo up front: reading which units are enabled needs no
    # privilege, so a sync that turns out to have nothing to do — the usual
    # case — should not cost a password. Escalate at the first actual change.
    # require_sudo is idempotent and free once the timestamp is cached, so
    # calling it per change is not calling it repeatedly.
    say "Making systemd match $SESSIONS_CONF"
    local n changed=0
    for n in $(session_names); do
        if [ "$(session_auto "$n")" = yes ]; then
            if unit_enabled "$n"; then skip "$n already enabled"
            else
                require_sudo "enable $(unit_of "$n")"
                unit_enable "$n" && { ok "enabled $(unit_of "$n")"; changed=1; }
            fi
        else
            if unit_enabled "$n"; then
                require_sudo "disable $(unit_of "$n")"
                unit_disable "$n" && { ok "disabled $(unit_of "$n")"; changed=1; }
            else skip "$n stays disabled (noautostart)"; fi
        fi
    done
    # Units enabled for sessions that are no longer registered would come back
    # on the next boot and fail, so retire them here.
    for n in $(enabled_unit_names); do
        session_known "$n" && continue
        require_sudo "retire $(unit_of "$n")"
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
    [ -n "$dir" ] || { warn "'$name' is not registered — add it with: curl.sh session add $name <dir>"; return 1; }
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
        require_sudo "start $(unit_of "$name")"
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
            # Reading a unit's status needs no privilege, and asking for one
            # here would mean the explanation of a failure came with a password
            # prompt attached.
            systemctl status "$(unit_of "$name")" --no-pager -n 8 2>/dev/null \
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
        require_sudo "stop $(unit_of "$name")"
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
        require_sudo "restart $(unit_of "$name")"
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
    [ -n "${names// /}" ] || { warn "no sessions registered — add one with: curl.sh session add <name> <dir>"; return 1; }
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
    warn "could not confirm Remote Control connected — try: curl.sh session doctor $name"
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
        printf '  %s\n' "${C_DIM}nothing registered yet — curl.sh session add <name> <dir>${C_RESET}"
    fi
    # Sessions running that nobody registered: surface them rather than hide them.
    for r in $(running_names); do
        session_known "$r" || printf '  %-3s %-13s %-9s %-6s %-8s %-5s %s\n' \
            '-' "$r" 'running' '-' '-' '-' "${C_DIM}(not registered)${C_RESET}"
    done
    printf '\n'
}

nth_session() { sessions_read | awk -F'\t' -v i="$1" 'NR == i { print $1 }'; }

# One row of the manage menu: key, label, hint, and 1 when it applies right now.
declare -a MO_KEYS MO_LABELS MO_HINTS MO_AVAIL
mo_row() { MO_KEYS+=("$1"); MO_LABELS+=("$2"); MO_HINTS+=("$3"); MO_AVAIL+=("$4"); }

# Every action has a fixed key and a fixed position, whatever state the session
# is in. An earlier version built the list from what was possible, which meant
# the numbers moved: "5" was Yolo on a running session and Logs on a stopped
# one, so muscle memory toggled the wrong setting. Actions that do not apply
# are dimmed and refused, never renumbered away.
manage_one() {
    local name="$1" choice rem yolo auto running=0 notrunning=1 i line
    MO_KEYS=(); MO_LABELS=(); MO_HINTS=(); MO_AVAIL=()
    rem="$(session_remote "$name")"
    yolo="$(session_yolo "$name")"
    auto="$(session_auto "$name")"
    session_running "$name" && { running=1; notrunning=0; }

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

    mo_row a "attach"         "$([ "$running" = 1 ] && printf 'tmux attach -t %s' "$(tmux_name "$name")" || printf 'not running')" "$running"
    mo_row s "start"          "$([ "$running" = 1 ] && printf 'already running' || printf 'start it')" "$notrunning"
    mo_row r "restart"        "$([ "$running" = 1 ] && printf 'stop it and start a fresh one' || printf 'not running')" "$running"
    mo_row x "stop"           "$([ "$running" = 1 ] && printf 'stop it' || printf 'not running')" "$running"
    # One entry per setting, cycling, labelled with where it will land rather
    # than making you work it out.
    mo_row m "remote control" "$(case "$rem" in
                                    no)          printf 'off → server mode' ;;
                                    server)      printf 'server mode → interactive' ;;
                                    interactive) printf 'interactive → off' ;;
                                esac)" 1
    mo_row y "yolo"           "$([ "$yolo" = yes ] && printf 'on → off' || printf 'off → on')" 1
    mo_row b "start at boot"  "$([ "$auto" = yes ] && printf 'on → off' || printf 'off → on')" 1
    mo_row l "logs"           "tail this session's output" 1
    mo_row q "back"           '' 1

    # Pad the plain text first, then colourise, or the columns drift.
    for i in "${!MO_KEYS[@]}"; do
        printf -v line '%2d) %s  %-16s' "$((i + 1))" "${MO_KEYS[i]}" "${MO_LABELS[i]}"
        if [ "${MO_AVAIL[i]}" = 1 ]; then
            printf '  %s %s\n' "$line" "${C_DIM}${MO_HINTS[i]}${C_RESET}"
        else
            printf '  %s\n' "${C_DIM}${line} ${MO_HINTS[i]}${C_RESET}"
        fi
    done
    # "back" is the only choice that is always safe and always available, so it
    # is what a stray Enter does. Nothing that starts, stops or attaches sits
    # under a blank keystroke.
    # Every entry here is one character, number or letter, so one keypress is
    # enough. Enter stays what it was — back — rather than becoming a redraw:
    # this menu does one thing and returns, so there is nothing to redraw into.
    choice="$(ask_key "Choice [Enter = back]: ")"
    printf '\n'

    local key='' idx=-1 act=''
    case "$choice" in
        [0-9])
            if [ "$choice" -ge 1 ] && [ "$choice" -le "${#MO_KEYS[@]}" ]; then
                idx=$((choice - 1)); key="${MO_KEYS[idx]}"
            else
                warn "no entry numbered $choice"; return 0
            fi ;;
        ''|q) key=q ;;
        a|e)  key=a ;;
        s)    key=s ;;
        r)    key=r ;;
        x|k)  key=x ;;
        m)    key=m ;;
        y)    key=y ;;
        b)    key=b ;;
        l)    key=l ;;
        *)    warn "unrecognised choice '$choice'"; return 0 ;;
    esac
    if [ "$idx" -lt 0 ]; then
        for i in "${!MO_KEYS[@]}"; do
            [ "${MO_KEYS[i]}" = "$key" ] && { idx=$i; break; }
        done
    fi

    if [ "${MO_AVAIL[idx]}" != 1 ]; then
        warn "'$name' is $([ "$running" = 1 ] && printf running || printf 'not running') — ${MO_LABELS[idx]} does not apply"
        return 0
    fi

    case "$key" in
        a) act=enter ;;
        s) act=start ;;
        r) act=restart ;;
        x) act=stop ;;
        m) act=remote ;;
        y) act=yolo ;;
        b) act=autostart ;;
        l) act=logs ;;
        q) act=back ;;
    esac

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

session_menu() {
    local input name
    while true; do
        print_table
        printf '  %s\n' "${C_DIM}1-9 = manage that one · n = new session · s = start all · r = restart all${C_RESET}"
        printf '  %s\n' "${C_DIM}x = stop all · y = sync systemd with the config · q = back${C_RESET}"
        # One key means one digit, so a tenth session cannot be picked from the
        # table. Say so rather than leaving it to be discovered, and point at
        # the spelling that does still reach it.
        [ "$(session_count)" -gt 9 ] && \
            printf '  %s\n' "${C_YELLOW}more than 9 sessions — reach the rest by name: curl.sh session <name>${C_RESET}"
        input="$(ask_key "Choice: ")"
        case "$input" in
            '')  continue ;;
            q)   return 0 ;;
            n)   new_session_interactive ;;
            s)   printf '\n'; for_each start_one   "$(autostart_names | tr '\n' ' ')" ;;
            r)   printf '\n'; for_each restart_one "$(autostart_names | tr '\n' ' ')" ;;
            x)   printf '\n'; for_each stop_one ;;
            y)   printf '\n'; sync_units ;;
            [1-9])
                name="$(nth_session "$input")"
                if [ -n "$name" ]; then manage_one "$name"; else warn "no session numbered $input"; fi ;;
            *)   warn "unrecognised choice '$input'" ;;
        esac
    done
}

# --------------------------------------------------------- new session wizard --
# Was referenced by the menu and by `curl.sh session new` but never defined, so both
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
        printf '\n# added by curl.sh\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$rc"
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
	# Written by curl.sh as a STUB. Everything between the EDIT markers is
	# yours. curl.sh will not overwrite this file once you have edited it; it
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
# project is a line in the registry plus `curl.sh session sync` — never a new unit.
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
    require_sudo "write $UNIT_PATH"
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
# Your own crontab needs no privilege to read or write. Reaching for
# "sudo crontab -u you" meant the read-only "curl.sh session status" — which only
# wants to know whether a screen-era @reboot line is still lying around —
# asked for a password.
crontab_get() {
    [ "$(id -un)" = "$TARGET_USER" ] && { crontab -l 2>/dev/null; return 0; }
    $SUDO crontab -u "$TARGET_USER" -l 2>/dev/null
}
crontab_put() {
    [ "$(id -un)" = "$TARGET_USER" ] && { crontab -; return; }
    require_sudo "edit $TARGET_USER's crontab"
    $SUDO crontab -u "$TARGET_USER" -
}

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
    require_sudo "install packages and write the systemd unit"
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
    printf '  %s\n' "start everything:  curl.sh session start"
    printf '  %s\n' "watch one:         tmux attach -t ${SESSION_PREFIX}<name>"
}

status() {
    printf '%s\n' "${C_BOLD}claude sessions${C_RESET}"
    print_table
    printf '  %-14s %s\n' 'registry' "$SESSIONS_CONF $([ -r "$SESSIONS_CONF" ] || echo '(missing)')"
    printf '  %-14s %s\n' 'runner'   "$(tilde "$RUNNER") $([ -x "$RUNNER" ] || echo '(missing)')"
    printf '  %-14s %s\n' 'logs'     "$(tilde "$SESSION_LOG_DIR")/<name>.log"
    if have_systemd; then
        printf '  %-14s %s\n' 'unit' "$UNIT_PATH $([ -r "$UNIT_PATH" ] || echo '(missing — run: curl.sh session install)')"
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
        warn "screen-era leftovers found — clear them with: curl.sh session migrate"
    fi
    if sessions_read | awk -F'\t' '$4 != "no" { found = 1 } END { exit !found }'; then
        printf '  %-14s %s\n' 'remote' "some sessions use Remote Control — see claude.ai/code"
        [ -n "${ANTHROPIC_API_KEY:-}" ] && warn "ANTHROPIC_API_KEY is set; Remote Control will refuse it"
    fi
}

# Everything you need to see when a session is not showing up.
doctor() {
    local only="${1:-}" n dir auto remote yolo dump
    printf '%s\n\n' "${C_BOLD}curl.sh doctor${C_RESET}"

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
                systemctl status "$(unit_of "$n")" --no-pager -n 6 2>/dev/null | sed 's/^/        /'
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
    require_sudo "remove $UNIT_PATH and disable the units"
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

enter_default() {
    local live count
    live="$(running_names)"
    count="$(printf '%s\n' "$live" | grep -c .)"
    if [ "$count" -eq 1 ]; then
        enter_one "$live"
    elif [ "$count" -eq 0 ]; then
        die "nothing is running. Start one with: curl.sh session start <name>"
    else
        warn "several sessions are running — name one:"
        printf '%s\n' "$live" | sed 's/^/    /' >&2
        exit 1
    fi
}

cmd_add() {
    [ $# -ge 2 ] || die "usage: curl.sh session add <name> <dir> [--no-autostart] [--no-yolo] [--remote]"
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

session_usage() {
    cat <<-USAGE
	${C_BOLD}curl.sh session${C_RESET} $VERSION — Claude Code unattended in tmux, started by systemd

	  curl.sh session [command]        (was: claude.sh [command], removed in 10.0.0)

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
	  Adding a project is one line plus "curl.sh session sync". One templated unit,
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

# The session half of the CLI: "curl.sh session <command>". The banner, the
# version check and the -v stripping are the outer main's job now, so this only
# does the part that is specific to sessions.
cmd_session() {
    local cmd="${1:-}"
    vlog "session: user=$TARGET_USER home=$TARGET_HOME registry=$SESSIONS_CONF"
    migrate_legacy_config
    [ $# -gt 0 ] && shift
    case "$cmd" in
        ''|default)
            if [ "$(session_count)" -eq 0 ] && [ ! -x "$RUNNER" ]; then
                provision
                for_each start_one "$(autostart_names | tr '\n' ' ')"
            else
                session_menu
            fi ;;
        install|setup)  provision ;;
        add)            cmd_add "$@" ;;
        new)            new_session_interactive ;;
        rm|remove)      [ $# -ge 1 ] || die "usage: curl.sh session rm <name>"; session_remove "$1" ;;
        list|ls)        print_table ;;
        sync)           sync_units ;;
        remote)
            [ $# -ge 2 ] || die "usage: curl.sh session remote <name> on|interactive|off"
            session_set_flag "$1" remote "$2" ;;
        yolo)
            [ $# -ge 2 ] || die "usage: curl.sh session yolo <name> on|off"
            session_set_flag "$1" yolo "$2" ;;
        autostart)
            [ $# -ge 2 ] || die "usage: curl.sh session autostart <name> on|off"
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
        help|-h|--help) session_usage ;;
        *)
            if session_known "$cmd"; then manage_one "$cmd"; else session_usage; die "unknown session command '$cmd'."; fi ;;
    esac
}

# ======================================================== end claude sessions ==

# ---------------------------------------------------------------- the catalog --
# Order matters: this is the order things get installed in, so git comes early
# and the Claude Code hand-off comes last.
PKG_KEYS=(update    git     gh      screen  btop     docker                 tailscale       purplemux       claude)
PKG_BLURB=(
    "apt update && apt full-upgrade"
    "version control"
    "GitHub CLI"
    "detachable terminal sessions"
    "resource monitor"
    "Docker Engine + Compose plugin"
    "mesh VPN"
    "web terminal multiplexer for Claude Code (pulls in Node 20+ and tmux)"
    "Claude Code + unattended tmux sessions"
)

# What each entry needs. PKG_NEEDS names other catalog entries, and those get
# ticked for you when you select something that depends on them. PKG_ALSO names
# prerequisites that are not in the catalog and so cannot be ticked — they are
# printed instead, so the checklist never installs more than it showed you.
#
# Only claude actually depends on another catalog entry. The rest of what these
# steps pull in (tmux, curl, Node) has no entry of its own.
PKG_NEEDS=(
    ""          # update
    ""          # git
    ""          # gh
    ""          # screen
    ""          # btop
    ""          # docker
    ""          # tailscale
    ""          # purplemux
    "git"       # claude — provision installs it before anything else
)
PKG_ALSO=(
    ""                          # update
    ""                          # git
    ""                          # gh
    ""                          # screen
    ""                          # btop
    ""                          # docker
    ""                          # tailscale
    "Node 20+ and tmux"         # purplemux
    "tmux and Claude Code"      # claude
)

# check_<key> prints a short state string; empty output means "not installed".
check_update()    { printf 'action'; }
check_git()       { have git       && git --version 2>/dev/null | awk '{print $3}'; }
check_gh()        { have gh        && gh --version 2>/dev/null | head -1 | awk '{print $3}'; }
check_screen()    { have screen    && screen --version 2>/dev/null | awk '{print $3}'; }
check_btop()      { have btop      && printf 'installed'; }
check_docker()    { have docker    && docker --version 2>/dev/null | awk '{print $3}' | tr -d ','; }
check_tailscale() { have tailscale && tailscale version 2>/dev/null | head -1; }
pkg_json_version() {
    sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -1
}

# Read the version from package.json rather than running the binary: purplemux
# is a server, and an unrecognised --version could start it instead of printing.
#
# The binary is a symlink into node_modules, so resolving it finds the package
# directly. "npm root -g" answers the same question but takes the better part of
# a second, which the catalog then paid on every redraw; it is now only reached
# when the layout is one we do not recognise.
check_purplemux() {
    have purplemux || return 1
    local pj real root
    real="$(readlink -f "$(command -v purplemux)" 2>/dev/null)"
    # .../node_modules/purplemux/bin/purplemux.js -> .../node_modules/purplemux
    [ -n "$real" ] && [ -r "${real%/bin/*}/package.json" ] \
        && { pkg_json_version "${real%/bin/*}/package.json"; return 0; }

    for pj in /usr/lib/node_modules/purplemux/package.json \
              /usr/local/lib/node_modules/purplemux/package.json; do
        [ -r "$pj" ] && { pkg_json_version "$pj"; return 0; }
    done

    # Unrecognised layout — a user with an npm prefix in their profile puts
    # global packages somewhere else entirely. Worth the second, now that it is
    # the exception rather than every draw.
    root="$(npm root -g 2>/dev/null)"
    if [ -n "$root" ] && [ -r "$root/purplemux/package.json" ]; then
        pkg_json_version "$root/purplemux/package.json"
        return 0
    fi
    printf 'installed'
}

# The installer points ~/.local/bin/claude at
# ~/.local/share/claude/versions/<version>, so the version is the symlink
# target's name and reading it costs nothing. Running "claude --version" needs
# a login shell, which the catalog was paying for on every redraw.
check_claude() {
    local link ver
    link="$TARGET_HOME/.local/bin/claude"
    if [ -L "$link" ]; then
        ver="$(basename "$(readlink "$link")" 2>/dev/null)"
        # Only trust it if it looks like a version; if the layout ever changes,
        # fall through to asking rather than printing a directory name.
        case "$ver" in
            [0-9]*) printf '%s' "$ver"; return 0 ;;
        esac
    fi
    # Installed some other way, or not at all.
    as_user 'command -v claude >/dev/null 2>&1' || return 1
    as_user 'timeout 10 claude --version' 2>/dev/null | awk '{print $1}'
}

pkg_index() {
    local want="$1" i
    for i in "${!PKG_KEYS[@]}"; do
        [ "${PKG_KEYS[i]}" = "$want" ] && { printf '%s' "$i"; return 0; }
    done
    return 1
}

# Probing the catalog is not free — "npm root -g" for purplemux is the better
# part of a second on its own, and check_claude is two login shells — while the
# picker redraws after every single keystroke. Probe once into CHECK[] and
# refresh only when something may actually have changed underneath us.
# A separate flag rather than testing "${#CHECK[@]}": under set -u an array
# that has been declared but never assigned is an unbound variable, so the very
# first draw would die before it had probed anything.
CHECK=()
CHECK_FRESH=''
catalog_scan() {
    local i
    CHECK=()
    for i in "${!PKG_KEYS[@]}"; do
        CHECK[i]="$("check_${PKG_KEYS[i]}" 2>/dev/null)"
    done
    CHECK_FRESH=1
}
catalog_fresh() { [ -n "$CHECK_FRESH" ] || catalog_scan; }
catalog_stale() { CHECK_FRESH=''; }

# ------------------------------------------------------------- install steps --
apt_refresh() {
    # Refresh the package lists once per run, not once per package.
    [ -n "${_APT_REFRESHED:-}" ] && return 0
    $SUDO apt-get update -qq || warn "apt-get update failed"
    _APT_REFRESHED=1
}

install_update() {
    say "Updating Ubuntu"
    export DEBIAN_FRONTEND=noninteractive
    apt_refresh
    $SUDO apt-get upgrade -y -qq || { warn "apt-get upgrade failed"; return 1; }
    $SUDO apt-get autoremove -y -qq >/dev/null 2>&1
    ok "system packages up to date"
}

install_git()    { apt_refresh; apt_ensure git git; }

install_gh() {
    if have gh; then
        skip "gh already installed ($(gh --version 2>/dev/null | head -1 | awk '{print $3}'))"
    else
        say "Installing GitHub CLI"
        apt_refresh
        DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq ca-certificates curl || true

        $SUDO install -m 0755 -d /etc/apt/keyrings
        local key=/etc/apt/keyrings/githubcli-archive-keyring.gpg
        if [ ! -s "$key" ]; then
            $SUDO curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o "$key" \
                || { warn "could not fetch the GitHub CLI signing key"; return 1; }
            $SUDO chmod go+r "$key"
        fi

        local repo_line
        repo_line="deb [arch=$(dpkg --print-architecture) signed-by=$key] https://cli.github.com/packages stable main"
        if ! grep -qsxF "$repo_line" /etc/apt/sources.list.d/github-cli.list; then
            printf '%s\n' "$repo_line" | $SUDO tee /etc/apt/sources.list.d/github-cli.list >/dev/null
            $SUDO apt-get update -qq
        fi

        DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq gh \
            || { warn "gh install failed"; return 1; }
        ok "gh $(gh --version 2>/dev/null | head -1 | awk '{print $3}') installed"
    fi

    if as_user 'gh auth status >/dev/null 2>&1'; then
        skip "gh is already authenticated"
    else
        warn "gh is not signed in yet — run: gh auth login"
    fi
}
install_screen() { apt_refresh; apt_ensure screen screen; }

install_btop() {
    if have btop; then skip "btop already installed"; return 0; fi
    apt_refresh
    say "Installing btop"
    if DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq btop 2>/dev/null && have btop; then
        ok "btop installed (apt)"
    elif have snap && $SUDO snap install btop >/dev/null 2>&1; then
        ok "btop installed (snap)"
    else
        warn "btop unavailable on this release — falling back to htop"
        apt_ensure htop htop
    fi
}

install_docker() {
    if have docker && docker compose version >/dev/null 2>&1; then
        skip "docker + compose plugin already installed"
    else
        say "Installing Docker Engine + Compose plugin"
        apt_refresh
        DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq ca-certificates curl gnupg || true

        # shellcheck source=/dev/null
        . /etc/os-release
        local distro="${ID:-ubuntu}" codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
        case "$distro" in ubuntu|debian) ;; *) distro=ubuntu ;; esac
        [ -n "$codename" ] || { warn "cannot determine distro codename; skipping Docker"; return 1; }

        $SUDO install -m 0755 -d /etc/apt/keyrings
        if [ ! -s /etc/apt/keyrings/docker.asc ]; then
            $SUDO curl -fsSL "https://download.docker.com/linux/$distro/gpg" -o /etc/apt/keyrings/docker.asc \
                || { warn "could not fetch Docker GPG key"; return 1; }
            $SUDO chmod a+r /etc/apt/keyrings/docker.asc
        fi

        local repo_line
        repo_line="deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$distro $codename stable"
        if ! grep -qsxF "$repo_line" /etc/apt/sources.list.d/docker.list; then
            printf '%s\n' "$repo_line" | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
            $SUDO apt-get update -qq
        fi

        DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq \
            docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
            || { warn "Docker install failed"; return 1; }
        ok "docker $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ,) installed"
    fi

    $SUDO systemctl enable --now docker >/dev/null 2>&1 || true

    if id -nG "$TARGET_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
        skip "$TARGET_USER already in the docker group"
    else
        $SUDO usermod -aG docker "$TARGET_USER" \
            && warn "added $TARGET_USER to the docker group — log out and back in for it to apply"
    fi
}

# purplemux needs Node.js 20+; Ubuntu's own nodejs package is usually older, so
# pull it from NodeSource when what is here is too old.
NODE_MIN=20
ensure_node() {
    local cur=0
    have node && cur="$(node -v 2>/dev/null | sed 's/^v\([0-9]*\).*/\1/')"
    if [ "${cur:-0}" -ge "$NODE_MIN" ]; then
        skip "node $(node -v 2>/dev/null) already satisfies >= v$NODE_MIN"
        return 0
    fi
    if [ "${cur:-0}" -gt 0 ]; then
        say "Upgrading Node.js (found v$cur, purplemux needs $NODE_MIN+)"
    else
        say "Installing Node.js $NODE_MIN (purplemux needs $NODE_MIN+)"
    fi
    apt_refresh
    DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq ca-certificates curl gnupg || true

    $SUDO install -m 0755 -d /etc/apt/keyrings
    local key=/etc/apt/keyrings/nodesource.gpg
    if [ ! -s "$key" ]; then
        curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | $SUDO gpg --dearmor -o "$key" \
            || { warn "could not fetch the NodeSource signing key"; return 1; }
        $SUDO chmod a+r "$key"
    fi

    local src=/etc/apt/sources.list.d/nodesource.sources want
    want="$(printf 'Types: deb\nURIs: https://deb.nodesource.com/node_%s.x/\nSuites: nodistro\nComponents: main\nSigned-By: %s\n' "$NODE_MIN" "$key")"
    if [ "$(cat "$src" 2>/dev/null)" != "$want" ]; then
        printf '%s' "$want" | $SUDO tee "$src" >/dev/null
        $SUDO apt-get update -qq
    fi

    DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq nodejs \
        || { warn "Node.js install failed"; return 1; }
    ok "node $(node -v 2>/dev/null) installed"
}

# ------------------------------------------------------- purplemux as a unit --
# `purplemux` with no arguments (or `purplemux start`) runs the server in the
# foreground, which is exactly what Type=simple wants. Its state lives in
# ~/.purplemux, so the unit has to run as the invoking user rather than root.
PMUX_UNIT=/etc/systemd/system/purplemux.service
PMUX_PORT="${CURL_SH_PMUX_PORT:-8022}"

pmux_unit_text() {
    local exec; exec="$(command -v purplemux 2>/dev/null)"
    [ -n "$exec" ] || exec="/usr/bin/env purplemux"
    cat <<UNIT
[Unit]
Description=purplemux — web terminal multiplexer for Claude Code
Documentation=https://github.com/subicura/purplemux
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$TARGET_USER
Environment=NODE_ENV=production
Environment=PMUX_PORT=$PMUX_PORT
# purplemux looks for Claude Code at ~/.local/bin/claude, which is not on the
# default systemd PATH.
Environment=PATH=$TARGET_HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
WorkingDirectory=$TARGET_HOME
ExecStart=$exec start
Restart=on-failure
RestartSec=5
KillMode=mixed
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target
UNIT
}

# Write /etc/systemd/system/purplemux.service and enable it. An existing unit
# that differs is backed up rather than silently overwritten — someone may have
# hand-tuned the port or the environment.
install_purplemux_service() {
    have_systemd || { warn "no systemd here — skipping the service"; return 1; }

    local tmp; tmp="$(mktemp)"
    pmux_unit_text > "$tmp"

    if [ -f "$PMUX_UNIT" ] && cmp -s "$tmp" "$PMUX_UNIT"; then
        skip "$PMUX_UNIT already up to date"
    else
        if [ -f "$PMUX_UNIT" ]; then
            $SUDO cp -p "$PMUX_UNIT" "$PMUX_UNIT.bak" \
                && warn "kept your existing unit as $PMUX_UNIT.bak"
        fi
        $SUDO install -m 0644 "$tmp" "$PMUX_UNIT" \
            || { rm -f "$tmp"; warn "could not write $PMUX_UNIT"; return 1; }
        ok "wrote $PMUX_UNIT (runs as $TARGET_USER on port $PMUX_PORT)"
    fi
    rm -f "$tmp"

    $SUDO systemctl daemon-reload >/dev/null 2>&1
    if $SUDO systemctl enable --now purplemux >/dev/null 2>&1; then
        ok "purplemux service enabled and started"
    else
        warn "enable failed — check: systemctl status purplemux"
        return 1
    fi

    skip "first run needs onboarding in a browser: http://localhost:$PMUX_PORT"
    skip "it advertises the machine IP — reach it over Tailscale rather than opening the port"
}

install_purplemux() {
    if have purplemux; then
        skip "purplemux $(check_purplemux) already installed"
    else
        say "Installing purplemux"
        # Prerequisites first, in the same step: tmux and Node.js 20+.
        apt_refresh
        apt_ensure tmux tmux || return 1
        ensure_node || return 1
        have npm || { warn "npm is missing even after installing Node.js"; return 1; }
        $SUDO npm install -g purplemux --silent \
            || { warn "npm install -g purplemux failed"; return 1; }
        have purplemux || { warn "purplemux is not on PATH after install"; return 1; }
        ok "purplemux $(check_purplemux) installed"
    fi

    # Running it by hand is fine, but it only survives as long as the terminal
    # does. Offer the unit rather than installing it unasked — plenty of people
    # want to try it once before committing the box to it.
    if ! have_systemd; then
        skip "start it with: purplemux   (then open http://localhost:$PMUX_PORT)"
    elif systemctl is-enabled purplemux >/dev/null 2>&1; then
        skip "already enabled as a systemd service"
        install_purplemux_service
    else
        local reply
        reply="$(ask "  also run it as a service, started at boot? [y/N] " n)"
        case "${reply,,}" in
            y|yes) install_purplemux_service ;;
            *)     skip "start it with: purplemux   (then open http://localhost:$PMUX_PORT)"
                   skip "the service can be added later: curl.sh purplemux-service" ;;
        esac
    fi
}

install_tailscale() {
    if have tailscale; then
        skip "tailscale already installed ($(tailscale version 2>/dev/null | head -1))"
    else
        say "Installing Tailscale"
        curl -fsSL https://tailscale.com/install.sh | $SUDO sh \
            || { warn "Tailscale install failed"; return 1; }
        ok "tailscale installed"
    fi
    if tailscale status >/dev/null 2>&1; then
        skip "tailscale is already connected"
    else
        warn "tailscale is not connected yet — run: sudo tailscale up"
    fi
}

# Claude Code and its sessions used to live in a second script this one fetched
# and ran. They are in this file now, so the catalog entry just calls it.
install_claude() { provision; }


# ------------------------------------------------------- docker containers --
# Each entry is a compose stack under $STACKS_DIR/<name>, which is also the
# directory Dockge manages — so anything installed here shows up in Dockge ready
# to edit, start and stop.
STACKS_DIR="${CURL_SH_STACKS_DIR:-/opt/stacks}"

DC_KEYS=(cloudflared beszel-agent dockge)
DC_BLURB=(
    "Cloudflare Tunnel connector"
    "Beszel monitoring agent (reports to a Beszel hub)"
    "web UI for docker compose stacks, on port 5001"
)

# Secrets each stack needs: VAR|prompt|required(yes/no)
dc_secrets() {
    case "$1" in
        cloudflared)
            printf '%s\n' "TUNNEL_TOKEN|Tunnel token (Zero Trust dashboard -> Networks -> Tunnels)|yes" ;;
        beszel-agent)
            printf '%s\n' \
                "BESZEL_HUB_URL|Beszel hub URL (e.g. http://192.168.1.10:8090)|yes" \
                "BESZEL_TOKEN|Agent token (hub -> Add System, or Settings -> Tokens)|yes" \
                "BESZEL_KEY|Agent public key (shown alongside the token)|yes" ;;
        *) : ;;
    esac
}

dc_dir() { printf '%s\n' "$STACKS_DIR/$1"; }

# Container states for the whole table, fetched once per draw. Drawing a menu
# must never stop to ask for a password: the old version ran "$SUDO docker ps"
# twice per row, so the prompt landed half way down the table and mangled it,
# before the user had chosen anything privileged to do. Try unprivileged docker
# first, then a non-interactive sudo, and settle for an unknown state rather
# than interrupting the table.
DC_PS=''            # "<name> <state>" lines
DC_PS_OK=''         # set when we managed to read docker at all
DC_PS_SCANNED=''
# Empty when docker works as us. "curl.sh docker" puts you in the docker group
# precisely so that it does, and then reaching for sudo anyway asks for a
# password the group membership already made unnecessary.
DOCKER_SUDO="$SUDO"
dc_scan() {
    DC_PS=''; DC_PS_OK=''; DC_PS_SCANNED=1; DOCKER_SUDO="$SUDO"
    have docker || return 0
    if DC_PS="$(docker ps -a --format '{{.Names}} {{.State}}' 2>/dev/null)"; then
        DC_PS_OK=1; DOCKER_SUDO=''; return 0
    fi
    if [ -n "$SUDO" ] && DC_PS="$(sudo -n docker ps -a --format '{{.Names}} {{.State}}' 2>/dev/null)"; then
        DC_PS_OK=1; return 0
    fi
    DC_PS=''
    return 0
}

# Call after anything that starts, stops or creates a container.
dc_rescan() { DC_PS_SCANNED=''; }

dc_state() {
    [ -n "$DC_PS_SCANNED" ] || dc_scan
    local st
    if [ -z "$DC_PS_OK" ]; then
        # docker is here but we cannot read it without a password. Say so
        # rather than guessing from the compose file, which would report
        # "written" for something that is actually up.
        have docker && { printf '%s' '?'; return; }
        [ -r "$(dc_dir "$1")/docker-compose.yml" ] && { printf '%s' 'written'; return; }
        printf '%s' '-'; return
    fi
    st="$(printf '%s\n' "$DC_PS" | awk -v n="$1" '$1 == n { print $2; exit }')"
    case "$st" in
        running) printf '%s' 'running'; return ;;
        ?*)      printf '%s' 'stopped'; return ;;
    esac
    [ -r "$(dc_dir "$1")/docker-compose.yml" ] && { printf '%s' 'written'; return; }
    printf '%s' '-'
}

dc_compose_for() {
    local name="$1" uid gid
    uid="$(id -u "$TARGET_USER" 2>/dev/null || echo 1000)"
    gid="$(id -g "$TARGET_USER" 2>/dev/null || echo 1000)"
    case "$name" in
        cloudflared) cat <<-'YAML'
	services:
	  cloudflared:
	    image: cloudflare/cloudflared:latest
	    container_name: cloudflared
	    restart: unless-stopped
	    command: tunnel --no-autoupdate run --token ${TUNNEL_TOKEN}
	YAML
            ;;
        beszel-agent) cat <<-'YAML'
	services:
	  beszel-agent:
	    image: henrygd/beszel-agent:latest
	    container_name: beszel-agent
	    restart: unless-stopped
	    network_mode: host
	    volumes:
	      - ./beszel_agent_data:/var/lib/beszel-agent
	      - /var/run/docker.sock:/var/run/docker.sock:ro
	    environment:
	      LISTEN: ${BESZEL_LISTEN:-45876}
	      HUB_URL: ${BESZEL_HUB_URL}
	      TOKEN: ${BESZEL_TOKEN}
	      KEY: ${BESZEL_KEY}
	YAML
            ;;
        dockge) cat <<-YAML
	services:
	  dockge:
	    image: louislam/dockge:1
	    container_name: dockge
	    restart: unless-stopped
	    ports:
	      - 5001:5001
	    volumes:
	      - /var/run/docker.sock:/var/run/docker.sock
	      - ./data:/app/data
	      - $STACKS_DIR:$STACKS_DIR
	    environment:
	      - DOCKGE_STACKS_DIR=$STACKS_DIR
	      - PUID=$uid
	      - PGID=$gid
	YAML
            ;;
    esac
}

# Ask for whatever the stack needs and write it beside the compose file. An
# empty answer is allowed: the stack is written but not started, so you can fill
# the file in later rather than being forced to have the value to hand.
dc_write_env() {
    local name="$1" dir="$2" var prompt required missing=0 val
    local tmp; tmp="$(mktemp)"
    printf '# %s — read by docker compose from this directory.\n' "$name" > "$tmp"
    while IFS='|' read -r var prompt required; do
        [ -n "$var" ] || continue
        val="$(ask "    $prompt: " '')"
        if [ -z "$val" ] && [ "$required" = yes ]; then
            missing=1
            printf '%s=REPLACE_ME\n' "$var" >> "$tmp"
        else
            printf '%s=%s\n' "$var" "$val" >> "$tmp"
        fi
    done < <(dc_secrets "$name")
    try_root install -m 0600 "$tmp" "$dir/.env"
    rm -f "$tmp"
    try_root chown "$TARGET_USER" "$dir/.env"
    return $missing
}

# Run something as ourselves, escalating only if that genuinely fails. The
# first stack has to create $STACKS_DIR, which needs root; from then on the
# directory belongs to $TARGET_USER and none of this does. Everything passed
# here is idempotent, so a failed first attempt costs nothing.
try_root() {
    "$@" 2>/dev/null && return 0
    [ -n "$SUDO" ] || return 1
    require_sudo "write to $STACKS_DIR"
    $SUDO "$@"
}

dc_compose_cmd() {
    [ -n "$DC_PS_SCANNED" ] || dc_scan
    # A version probe is not a reason to ask for a password.
    # shellcheck disable=SC2086  # $DOCKER_SUDO is "sudo" or nothing
    if $DOCKER_SUDO docker compose version >/dev/null 2>&1; then printf '%s' 'docker compose'
    elif have docker-compose; then printf '%s' 'docker-compose'
    else printf '%s' ''; fi
}

dc_install() {
    local name="$1" dir cc rc=0
    dir="$(dc_dir "$name")"

    if ! have docker; then
        warn "docker is not installed — installing it first"
        install_docker || { warn "cannot continue without docker"; return 1; }
    fi
    cc="$(dc_compose_cmd)"
    [ -n "$cc" ] || { warn "no docker compose available"; return 1; }

    say "Setting up $name in $dir"
    try_root mkdir -p "$dir"
    try_root chown "$TARGET_USER" "$dir"

    local tmp; tmp="$(mktemp)"
    dc_compose_for "$name" > "$tmp"
    if [ -r "$dir/docker-compose.yml" ] && ! cmp -s "$tmp" "$dir/docker-compose.yml"; then
        try_root cp -p "$dir/docker-compose.yml" "$dir/docker-compose.yml.bak"
        warn "kept your previous compose file as docker-compose.yml.bak"
    fi
    try_root install -m 0644 "$tmp" "$dir/docker-compose.yml"
    rm -f "$tmp"
    try_root chown "$TARGET_USER" "$dir/docker-compose.yml"
    ok "wrote $dir/docker-compose.yml"

    if [ -n "$(dc_secrets "$name")" ]; then
        if [ -r "$dir/.env" ] && ! grep -q 'REPLACE_ME' "$dir/.env" 2>/dev/null; then
            skip "$dir/.env already filled in"
        else
            say "  $name needs a few values (press Enter to skip and fill them in later)"
            if ! dc_write_env "$name" "$dir"; then
                warn "left REPLACE_ME in $dir/.env — not starting $name"
                skip "fill it in, then: cd $dir && $cc up -d"
                return 0
            fi
            ok "wrote $dir/.env"
        fi
    fi

    say "Starting $name"
    local out
    dc_rescan
    # shellcheck disable=SC2086  # $cc is "docker compose", two words on purpose
    if out="$( cd "$dir" && $DOCKER_SUDO $cc up -d 2>&1 )"; then
        ok "$name is up"
        [ "$name" = dockge ] && skip "open http://localhost:5001"
    else
        warn "$cc up -d failed:"
        printf '%s\n' "$out" | tail -4 | sed 's/^/         /' >&2
        skip "retry by hand: cd $dir && $cc up -d"
        rc=1
    fi
    return $rc
}

# start / stop / restart an already-installed stack. Installing is a separate
# path because it also writes files and asks for secrets.
dc_control() {
    local verb="$1" name="$2" dir cc args out
    dir="$(dc_dir "$name")"
    if [ ! -r "$dir/docker-compose.yml" ]; then
        warn "'$name' is not installed yet — Enter installs it"
        return 1
    fi
    cc="$(dc_compose_cmd)"
    [ -n "$cc" ] || { warn "no docker compose available"; return 1; }
    case "$verb" in
        start)   say "Starting $name";   args="up -d" ;;
        stop)    say "Stopping $name";   args="stop" ;;
        restart) say "Restarting $name"; args="restart" ;;
        *) warn "unknown action '$verb'"; return 1 ;;
    esac
    # shellcheck disable=SC2086  # $cc, $args and $DOCKER_SUDO are word-split on purpose
    if out="$( cd "$dir" && $DOCKER_SUDO $cc $args 2>&1 )"; then
        dc_rescan; dc_scan          # in the parent, so the $( ) below sees it
        ok "$name is now $(dc_state "$name")"
    else
        warn "$cc $args failed:"
        printf '%s\n' "$out" | tail -4 | sed 's/^/         /' >&2
        return 1
    fi
}

# Apply an action to everything ticked; complain if nothing is.
dc_apply() {
    local verb="$1" idx count=0 rc=0
    for idx in "${!DC_KEYS[@]}"; do [ "${DC_SELECTED[idx]}" = 1 ] && count=$((count + 1)); done
    if [ "$count" -eq 0 ]; then
        warn "nothing selected — tick some numbers first"
        return 1
    fi
    for idx in "${!DC_KEYS[@]}"; do
        [ "${DC_SELECTED[idx]}" = 1 ] || continue
        printf '\n'
        if [ "$verb" = install ]; then dc_install "${DC_KEYS[idx]}" || rc=1
        else dc_control "$verb" "${DC_KEYS[idx]}" || rc=1; fi
    done
    printf '\n'
    return $rc
}

dc_print_catalog() {
    local i key st pad mark
    # Scan HERE, in the parent shell. dc_state is called from a $( ) below, and
    # a subshell's cache dies with it — leaving one "docker ps" per row and a
    # DC_PS_OK the footer could never see.
    [ -n "$DC_PS_SCANNED" ] || dc_scan
    printf '\n  %-3s %-3s %-14s %-9s %s\n' '' '#' 'container' 'state' 'what it is'
    printf '  %s\n' "$(printf '%.0s-' {1..72})"
    for i in "${!DC_KEYS[@]}"; do
        key="${DC_KEYS[i]}"
        st="$(dc_state "$key")"
        printf -v pad '%-9s' "$st"
        case "$st" in
            running) pad="${C_GREEN}${pad}${C_RESET}" ;;
            stopped|written|'?') pad="${C_YELLOW}${pad}${C_RESET}" ;;
            *) pad="${C_DIM}${pad}${C_RESET}" ;;
        esac
        [ "${DC_SELECTED[i]:-0}" = 1 ] && mark="${C_GREEN}[x]${C_RESET}" || mark='[ ]'
        printf '  %b %-3s %-14s %b %s\n' "$mark" "$((i + 1))" "$key" "$pad" "${C_DIM}${DC_BLURB[i]}${C_RESET}"
    done
    if have docker && [ -z "$DC_PS_OK" ]; then
        printf '  %s\n' "${C_DIM}state is '?' — reading docker needs a password here, which this table will not ask for${C_RESET}"
    elif ! have docker; then
        printf '  %s\n' "${C_YELLOW}docker is not installed — installing any stack installs it first${C_RESET}"
    fi
    printf '\n'
}

declare -a DC_SELECTED
dc_reset() { local i; for i in "${!DC_KEYS[@]}"; do DC_SELECTED[i]=0; done; }

dc_index() {
    local want="$1" i
    for i in "${!DC_KEYS[@]}"; do
        [ "${DC_KEYS[i]}" = "$want" ] && { printf '%s' "$i"; return 0; }
    done
    return 1
}

docker_menu() {
    if [ -n "${ASSUME_YES:-}" ] || [ ! -r /dev/tty ]; then
        warn "not interactive — name what you want, e.g. curl.sh containers dockge"
        return 1
    fi
    dc_reset
    local input idx
    while true; do
        # One "docker ps -a" per draw keeps the table live without the six
        # privileged calls the old per-row probe made.
        dc_rescan
        printf '%s' "${C_BOLD}Docker containers${C_RESET}"
        dc_print_catalog
        printf '  %s\n' "${C_DIM}stacks live in $STACKS_DIR · 1-9 toggles · a = all · n = none${C_RESET}"
        printf '  %s\n' "${C_DIM}i = install · s = start · x = stop · r = restart · q = back${C_RESET}"
        # Install is "i", not Enter. Enter used to mean install here, which was
        # fine when this menu read a whole line and you had to mean it. Acting
        # on one keypress makes a stray Enter an install, and Enter is harmless
        # everywhere else in this script — so it redraws here too.
        input="$(ask_key "Choice: ")"
        case "$input" in
            '')  continue ;;
            q)   return 0 ;;
            a)   for idx in "${!DC_KEYS[@]}"; do DC_SELECTED[idx]=1; done ;;
            n)   dc_reset ;;
            i)   dc_apply install && dc_reset ;;
            s)   dc_apply start   && dc_reset ;;
            x)   dc_apply stop    && dc_reset ;;
            r)   dc_apply restart && dc_reset ;;
            [1-9])
                idx=$((input - 1))
                if [ "$idx" -lt "${#DC_KEYS[@]}" ]; then
                    [ "${DC_SELECTED[idx]}" = 1 ] && DC_SELECTED[idx]=0 || DC_SELECTED[idx]=1
                else warn "no entry numbered $input"; fi ;;
            *)   warn "unrecognised choice '$input'" ;;
        esac
    done
}

# ---------------------------------------------------------------- the picker --
# SELECTED[i] is 1 when entry i is chosen.
declare -a SELECTED

selection_reset() {
    local i
    for i in "${!PKG_KEYS[@]}"; do SELECTED[i]=0; done
}

# Turn entry $1 on, along with anything in the catalog it needs, and say what
# was added. Selecting something must never grow the list behind your back.
#
# Deselecting does NOT walk back the other way: having ticked claude and picked
# up git, unticking claude leaves git alone, because by then you have seen it
# and may well want it on its own.
select_with_deps() {
    local idx="$1" dep didx
    [ "${SELECTED[idx]:-0}" = 1 ] && return 0
    SELECTED[idx]=1
    for dep in ${PKG_NEEDS[idx]}; do
        didx="$(pkg_index "$dep")" || continue
        [ "${SELECTED[didx]:-0}" = 1 ] && continue
        select_with_deps "$didx"
        say "also ticked ${C_BOLD}$dep${C_RESET} — ${PKG_KEYS[idx]} needs it"
    done
    [ -n "${PKG_ALSO[idx]}" ] && \
        skip "${PKG_KEYS[idx]} also pulls in ${PKG_ALSO[idx]} (no entry of their own)"
    return 0
}

# Toggle, but turning on goes through select_with_deps.
select_toggle() {
    local idx="$1"
    if [ "${SELECTED[idx]:-0}" = 1 ]; then SELECTED[idx]=0
    else select_with_deps "$idx"; fi
}

# print_catalog [nomark]  — pad plain text first, then colourise, so escape
# sequences never throw the column widths off.
print_catalog() {
    local nomark="${1:-}" i key raw colour pad mark
    if [ -n "$nomark" ]; then
        printf '\n  %-3s %-11s %-13s %s\n' '#' 'name' 'installed' 'what it is'
    else
        printf '\n  %-3s %-3s %-11s %-13s %s\n' '' '#' 'name' 'installed' 'what it is'
    fi
    printf '  %s\n' "$(printf '%.0s-' {1..72})"
    catalog_fresh
    for i in "${!PKG_KEYS[@]}"; do
        key="${PKG_KEYS[i]}"
        raw="${CHECK[i]}"
        if [ "$key" = update ]; then raw='-'; colour="$C_DIM"
        elif [ -n "$raw" ];        then colour="$C_GREEN"
        else raw='no';                  colour="$C_DIM"
        fi
        printf -v pad '%-13s' "$raw"
        [ "${SELECTED[i]:-0}" = 1 ] && mark="${C_GREEN}[x]${C_RESET}" || mark='[ ]'
        if [ -n "$nomark" ]; then
            printf '  %-3s %-11s %b %s\n' "$((i + 1))" "$key" "${colour}${pad}${C_RESET}" "${C_DIM}${PKG_BLURB[i]}${C_RESET}"
        else
            printf '  %b %-3s %-11s %b %s\n' "$mark" "$((i + 1))" "$key" "${colour}${pad}${C_RESET}" "${C_DIM}${PKG_BLURB[i]}${C_RESET}"
        fi
    done
    printf '\n'
}

picker() {
    # Without a terminal, ask() returns the default forever and this loop would
    # never terminate. Name what you want instead.
    if [ -n "${ASSUME_YES:-}" ] || [ ! -r /dev/tty ]; then
        warn "not interactive — name what you want, e.g. curl.sh install git docker"
        return 1
    fi
    selection_reset
    local input tok idx count=0

    while true; do
        print_catalog
        printf '  %s\n' "${C_DIM}numbers toggle · a=all · m=missing only · n=none · q=back${C_RESET}"
        input="$(ask "Install [Enter to confirm]: " '')"

        case "$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')" in
            q|quit|exit) say "Nothing changed."; return 1 ;;
            a|all)  for idx in "${!PKG_KEYS[@]}"; do select_with_deps "$idx"; done; continue ;;
            n|none) selection_reset; continue ;;
            m|missing)
                selection_reset
                catalog_fresh
                for idx in "${!PKG_KEYS[@]}"; do
                    [ "${PKG_KEYS[idx]}" = update ] && continue
                    [ -z "${CHECK[idx]}" ] && SELECTED[idx]=1
                done
                continue ;;
            '')
                count=0
                for idx in "${!PKG_KEYS[@]}"; do
                    [ "${SELECTED[idx]}" = 1 ] && count=$((count + 1))
                done
                if [ "$count" -eq 0 ]; then
                    warn "nothing selected — pick some numbers, or q to quit"
                    continue
                fi
                return 0 ;;
        esac

        # Otherwise: a list of numbers and/or names to toggle.
        for tok in $(printf '%s' "$input" | tr ',' ' '); do
            if printf '%s' "$tok" | grep -qE '^[0-9]+$'; then
                idx=$((tok - 1))
                if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#PKG_KEYS[@]}" ]; then
                    select_toggle "$idx"
                else
                    warn "no entry numbered $tok"
                fi
            elif idx="$(pkg_index "$tok")"; then
                select_toggle "$idx"
            else
                warn "unknown entry '$tok'"
            fi
        done
    done
}

run_selection() {
    local i key failed=() done_=()
    printf '\n%s\n' "${C_BOLD}Installing on $(hostname) for $TARGET_USER${C_RESET}"
    require_sudo "install system packages"
    for i in "${!PKG_KEYS[@]}"; do
        [ "${SELECTED[i]}" = 1 ] || continue
        key="${PKG_KEYS[i]}"
        printf '\n'
        if "install_$key"; then done_+=("$key"); else failed+=("$key"); fi
    done

    printf '\n%s\n' "${C_BOLD}Done.${C_RESET}"
    [ ${#done_[@]}  -gt 0 ] && printf '  %s %s\n' "${C_GREEN}ok${C_RESET}    " "${done_[*]}"
    [ ${#failed[@]} -gt 0 ] && printf '  %s %s\n' "${C_RED}failed${C_RESET}" "${failed[*]}"
    [ ${#failed[@]} -eq 0 ]
}

select_by_name() {
    # select_by_name <name> [name...]  — used by the non-interactive path
    selection_reset
    local name idx
    for name in "$@"; do
        case "$name" in
            all)     for idx in "${!PKG_KEYS[@]}"; do select_with_deps "$idx"; done ;;
            missing)
                catalog_fresh
                for idx in "${!PKG_KEYS[@]}"; do
                    [ "${PKG_KEYS[idx]}" = update ] && continue
                    [ -z "${CHECK[idx]}" ] && select_with_deps "$idx"
                done ;;
            *)
                if idx="$(pkg_index "$name")"; then
                    select_with_deps "$idx"
                else
                    die "unknown package '$name'. Try: curl.sh list"
                fi ;;
        esac
    done
}

# ------------------------------------------------------------------ commands --
list_catalog() {
    selection_reset
    printf '%s' "${C_BOLD}Available${C_RESET}"
    print_catalog nomark
}

usage() {
    cat <<-USAGE
	${C_BOLD}curl.sh${C_RESET} $VERSION — set up an Ubuntu box: packages, containers, Claude Code

	  bash <(curl -Ss https://raw.githubusercontent.com/mkolakowski/curl/main/curl.sh) [command]

	${C_BOLD}Commands${C_RESET}
	  (none)              menu: claude sessions, containers, software
	  install <name>...   install the named entries without prompting
	  install all         install everything
	  install missing     install whatever is not there yet
	  list                show the catalog and what is already installed
	  containers [start|stop|restart] [name...]
	                      docker container stacks: cloudflared, beszel-agent,
	                      dockge. No arguments opens the checklist; a bare verb
	                      acts on every installed stack.
	  session <command>   Claude Code sessions — see: curl.sh session help
	  doctor [name]       why a session is not running or not connecting
	  purplemux-service   write and enable the purplemux systemd unit
	  update              apt update + full-upgrade only
	  reboot              reboot the machine
	  version             print the version and exit
	  help                this text

	${C_BOLD}Entries${C_RESET}
	  ${PKG_KEYS[*]}

	${C_BOLD}Environment${C_RESET}
	  CURL_SH_STACKS_DIR  where compose stacks are written (now: $STACKS_DIR)
	  CURL_SH_PMUX_PORT   port for the purplemux service (now: $PMUX_PORT)
	  ASSUME_YES=1        never prompt, take the defaults
	  NO_COLOR=1          plain output

	Claude Code sessions used to live in claude.sh. They are in this file now:
	  curl.sh session list        was: claude.sh list
	  curl.sh session add <name> <dir>
	The claude.sh URL was removed in 10.0.0; use curl.sh session.

	  $REPO_URL
	USAGE
}

# ------------------------------------------------------------- the home menu --
# Three domains that used to be two scripts. This routes and does nothing else:
# every action lives in the submenu it belongs to.
#
# The summary counts have to be cheap, because they are drawn before the user
# has asked for anything. Sessions and containers cost a "tmux ls" and one
# "docker ps -a"; the catalog is the expensive one, and is cached after the
# first draw.
home_summary_sessions() {
    local total running failed n
    total="$(session_count)"
    [ "$total" -gt 0 ] || { printf '%s' 'none registered'; return; }
    running=0; failed=0
    for n in $(session_names); do
        if session_running "$n"; then running=$((running + 1))
        elif unit_failed "$n"; then failed=$((failed + 1)); fi
    done
    printf '%d running, %d failed' "$running" "$failed"
}

home_summary_containers() {
    have docker || { printf '%s' 'docker not installed'; return; }
    local k st running=0 idle=0
    for k in "${DC_KEYS[@]}"; do
        st="$(dc_state "$k")"
        case "$st" in
            running) running=$((running + 1)) ;;
            stopped|written) idle=$((idle + 1)) ;;
        esac
    done
    printf '%d running, %d idle' "$running" "$idle"
}

home_summary_software() {
    local i n=0
    catalog_fresh
    for i in "${!PKG_KEYS[@]}"; do
        [ "${PKG_KEYS[i]}" = update ] && continue
        [ -n "${CHECK[i]}" ] && n=$((n + 1))
    done
    printf '%d of %d installed' "$n" "$((${#PKG_KEYS[@]} - 1))"
}

# Pad the plain label before wrapping it in colour, or the escape sequences
# push the summary column out of line.
home_row() {
    local pad
    printf -v pad '%-16s' "$2"
    printf '  %-3s %s %s\n' "$1" "${C_BOLD}${pad}${C_RESET}" "${C_DIM}$3${C_RESET}"
}

home_menu() {
    if [ -n "${ASSUME_YES:-}" ] || [ ! -r /dev/tty ]; then
        warn "not interactive — try: curl.sh help"
        return 1
    fi
    local input
    while true; do
        # dc_state reads a cache built in the parent; refresh it once per draw.
        dc_rescan
        printf '\n'
        home_row c 'Claude sessions' "$(home_summary_sessions)"
        home_row d 'Docker'          "$(home_summary_containers)"
        home_row s 'Software'        "$(home_summary_software)"
        printf '\n  %s\n' "${C_DIM}o = doctor · ? = help · q = quit${C_RESET}"
        # One keypress, no Enter. Every choice here is a single character, so
        # asking for Enter as well was a keystroke that bought nothing. The
        # submenus still read a line, because they take numbers and lists.
        input="$(ask_key "Choice: ")"
        case "$input" in
            '')  continue ;;
            q)   return 0 ;;
            c)   cmd_session ;;
            d)   docker_menu; catalog_stale ;;
            # i was this row's key while it was called Installers. It is not
            # drawn any more, but it stays accepted: the rename is not a reason
            # to punish anyone whose fingers learned the old one.
            s|i) picker && run_selection; catalog_stale ;;
            o)   doctor ;;
            \?|h) usage ;;
            *)   warn "unrecognised choice '$input'" ;;
        esac
    done
}

main() {
    # -v / --verbose may appear anywhere; strip it before dispatch. It only
    # means anything to the session half, but accepting it everywhere is
    # cheaper to explain than accepting it in one place.
    local a args=()
    for a in "$@"; do
        case "$a" in
            -v|--verbose) VERBOSE=1 ;;
            *) args+=("$a") ;;
        esac
    done
    set -- ${args+"${args[@]}"}

    # version prints the version and nothing else, banner included. Look past a
    # leading "session" so that "curl.sh session version" answers the same way
    # "curl.sh version" does, rather than printing the session banner.
    local probe="${1:-}"
    case "$probe" in session|sessions) probe="${2:-}" ;; esac
    case "$probe" in
        version|--version|-V) printf '%s\n' "$VERSION"; return 0 ;;
    esac
    banner
    case "${1:-}" in
        '')
            home_menu ;;
        session|sessions)
            shift
            cmd_session "$@" ;;
        doctor|diag)
            shift
            doctor "${1:-}" ;;
        install|add|i)
            shift
            [ $# -gt 0 ] || die "nothing named. Try: curl.sh install all"
            select_by_name "$@"
            run_selection ;;
        list|ls)        list_catalog ;;
        containers|docker-containers)
            shift 2>/dev/null || true
            local verb=install
            case "${1:-}" in
                install|start|stop|restart) verb="$1"; shift ;;
            esac
            if [ $# -gt 0 ]; then
                local c rc=0
                for c in "$@"; do
                    dc_index "$c" >/dev/null || die "unknown container '$c'. Try: curl.sh containers"
                    if [ "$verb" = install ]; then dc_install "$c" || rc=1
                    else dc_control "$verb" "$c" || rc=1; fi
                done
                return $rc
            fi
            # A bare verb with no names acts on everything already installed.
            if [ "$verb" != install ]; then
                local k rc=0 acted=0
                for k in "${DC_KEYS[@]}"; do
                    [ -r "$(dc_dir "$k")/docker-compose.yml" ] || continue
                    acted=1; dc_control "$verb" "$k" || rc=1
                done
                [ "$acted" = 1 ] || warn "no container stacks installed yet"
                return $rc
            fi
            docker_menu ;;
        purplemux-service)
            have purplemux || die "purplemux is not installed. Try: curl.sh purplemux"
            require_sudo "write and enable $PMUX_UNIT"
            install_purplemux_service ;;
        update)         require_sudo "run apt update and full-upgrade"; install_update ;;
        reboot)         say "Rebooting…"; $SUDO reboot ;;
        help|-h|--help) usage ;;
        *)
            # Bare names are a shorthand for `install <names>`.
            if pkg_index "$1" >/dev/null || [ "$1" = all ] || [ "$1" = missing ]; then
                select_by_name "$@"
                run_selection
            else
                usage; die "unknown command '$1'."
            fi ;;
    esac
}

main "$@"
