#!/usr/bin/env bash
#
# claude.sh — run Claude Code headlessly in detached screen sessions.
#
#   bash <(curl -Ss https://raw.githubusercontent.com/mkolakowski/curl/main/claude.sh) [command]
#
# Any number of sessions, each with its own working directory, listed one per
# line in ~/.config/claude-sessions.conf:
#
#   # name    work directory              flags
#   claude    /home/matt/work             autostart
#   api       /home/matt/work/api         autostart remote
#   scratch   /tmp/scratch                noautostart
#
#   autostart / noautostart   started by the @reboot entry, or not
#   remote / local            launch with Claude Code's Remote Control, so the
#                             session can be driven from claude.ai/code and the
#                             Claude mobile app while still running here
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
readonly VERSION="2.12.0"          # keep in step with the top entry of CHANGELOG.md
readonly REPO_URL="https://github.com/mkolakowski/curl"
readonly CRON_MARKER="# claude-session-boot (managed by claude.sh)"
# Entries written by the older combined curl.sh, so upgrades replace rather
# than duplicate them.
readonly CRON_MARKER_LEGACY="# claude-session-boot (managed by curl.sh)"
readonly TAB=$'\t'
# Bump when the generated boot script's contract changes (arguments it accepts,
# config it reads). An on-disk stub declaring anything else cannot be trusted to
# start the session we ask it for.
readonly STUB_VERSION=5

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
LEGACY_CONF="$TARGET_HOME/.config/claude-session.env"
BOOT_SCRIPT="$TARGET_HOME/.local/bin/claude-session-boot.sh"
BOOT_LOG="$TARGET_HOME/.local/state/claude-session-boot.log"
SESSION_LOG_DIR="$TARGET_HOME/.local/state/claude-sessions"

CLAUDE_CMD="${CLAUDE_CMD:-claude}"

# -------------------------------------------------------------- the registry --
# One session per line:  <name>  <work-dir>  [flags...]
# Flags are order-independent: autostart|noautostart and remote|local.
# Anything after # is a comment. Work directories may not contain spaces.
# sessions_read emits: name<TAB>dir<TAB>autostart(yes|no)<TAB>remote(yes|no)
sessions_read() {
    [ -r "$SESSIONS_CONF" ] || return 0
    awk '{ sub(/#.*/, "") }
         NF >= 2 {
             auto = "yes"; remote = "no"
             for (i = 3; i <= NF; i++) {
                 if      ($i == "noautostart")        auto   = "no"
                 else if ($i == "autostart")          auto   = "yes"
                 else if ($i == "remote")             remote = "server"
                 else if ($i == "remote-interactive") remote = "interactive"
                 else if ($i == "local")              remote = "no"
             }
             print $1 "\t" $2 "\t" auto "\t" remote
         }' "$SESSIONS_CONF"
}

session_names()   { sessions_read | cut -f1; }
session_count()   { sessions_read | grep -c . ; }
session_field()   { sessions_read | awk -F'\t' -v n="$1" -v f="$2" '$1 == n { print $f; exit }'; }
session_dir()     { session_field "$1" 2; }
session_auto()    { session_field "$1" 3; }
session_remote()  { session_field "$1" 4; }
session_known()   { [ -n "$(session_field "$1" 1)" ]; }
autostart_names() { sessions_read | awk -F'\t' '$3 == "yes" { print $1 }'; }

sessions_header() {
    printf '%s\n' \
        '# Claude Code sessions, one per line. Managed by claude.sh, safe to edit.' \
        '#' \
        '#   <name>  <work directory>  [autostart|noautostart] [remote|remote-interactive|local]' \
        '#' \
        '# autostart           started by the @reboot entry (the default)' \
        '# remote              Remote Control server mode: claude remote-control.' \
        '#                     Drive it from claude.ai/code or the Claude app. There' \
        '#                     is no local prompt; the screen shows connection status.' \
        '# remote-interactive  a normal session that is ALSO reachable remotely:' \
        '#                     claude --remote-control. You can type on the box too.' \
        '#' \
        '# Work directories may not contain spaces.' \
        ''
}

# Rewrite the registry from parsed rows, with $1 excluded (may be empty).
sessions_rewrite_without() {
    local drop="${1:-}"
    { sessions_header
      sessions_read | awk -F'\t' -v drop="$drop" '
          $1 != drop {
              printf "%-11s %-33s %s%s\n", $1, $2, ($3 == "no" ? "noautostart" : "autostart"),
                     ($4 == "server" ? " remote" : ($4 == "interactive" ? " remote-interactive" : ""))
          }'
    }
}

sessions_write() {
    local tmp; tmp="$(mktemp)"
    cat > "$tmp"
    mkdir_for_user "$(dirname "$SESSIONS_CONF")"
    install -m 0644 "$tmp" "$SESSIONS_CONF"
    rm -f "$tmp"
    own "$SESSIONS_CONF"
}

session_add() {
    local name="$1" dir="$2" auto="${3:-autostart}" remote="${4:-}"
    case "$name" in *[!A-Za-z0-9._-]*|'') die "session name '$name' may only contain letters, digits, dot, dash and underscore." ;; esac
    case "$dir"  in *[[:space:]]*|'')     die "work directory '$dir' may not contain spaces." ;; esac
    dir="${dir/#\~/$TARGET_HOME}"
    # Replace in place when the name already exists, so toggling a flag does not
    # shuffle a session to the bottom and renumber the menu underneath you.
    { sessions_header
      sessions_read | awk -F'\t' -v n="$name" -v d="$dir" -v a="$auto" -v r="$remote" '
          function row(nm, dr, au, rm) { printf "%-11s %-33s %s%s\n", nm, dr, au, (rm != "" ? " " rm : "") }
          $1 == n { row(n, d, a, r); seen = 1; next }
          { row($1, $2, ($3 == "no" ? "noautostart" : "autostart"),
                ($4 == "server" ? "remote" : ($4 == "interactive" ? "remote-interactive" : ""))) }
          END { if (!seen) row(n, d, a, r) }'
    } | sessions_write
    mkdir_for_user "$dir"
    ok "registered '$name' -> $dir ($auto${remote:+, $remote})"
    [ -n "$remote" ] && { remote_preflight || true; }
    return 0
}

session_remove() {
    local name="$1"
    session_known "$name" || { skip "no session named '$name' in the registry"; return 0; }
    sessions_rewrite_without "$name" | sessions_write
    ok "removed '$name' from the registry (a running session is left alone)"
}

session_set_remote() {
    local name="$1" on="$2" auto rem
    session_known "$name" || die "no session named '$name'. See: claude.sh list"
    [ "$(session_auto "$name")" = no ] && auto=noautostart || auto=autostart
    case "$on" in
        on|server)        rem=remote ;;
        interactive)      rem='remote-interactive' ;;
        off|no|local)     rem='' ;;
        *) die "usage: claude.sh remote <name> on|interactive|off" ;;
    esac
    session_add "$name" "$(session_dir "$name")" "$auto" "$rem"
    if session_running "$name"; then
        warn "'$name' is running — restart it for this to take effect: claude.sh restart $name"
    fi
}

# Why Remote Control would refuse, as a list of reasons. Empty output means the
# preconditions look right. This exists because `claude --remote-control` does
# NOT fail when it cannot connect: it quietly starts an ordinary session and
# shows a notification you never see from a detached screen.
remote_blockers() {
    local probe api token base bedrock vertex claude_bin
    vlog "probing the session environment"
    # One login shell, not six: each as_user is a full `sudo bash -lc`, and on a
    # slow box six of them back to back looks exactly like a hang.
    # shellcheck disable=SC2016  # expanded in the session's own login shell
    probe="$(as_user_t 30 'printf "%s\n" "claude=$(command -v claude 2>/dev/null)" "api=${ANTHROPIC_API_KEY:-}" "token=${CLAUDE_CODE_OAUTH_TOKEN:-}" "base=${ANTHROPIC_BASE_URL:-}" "bedrock=${CLAUDE_CODE_USE_BEDROCK:-}" "vertex=${CLAUDE_CODE_USE_VERTEX:-}"')"
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
    if ! as_user_t 25 'claude auth status >/dev/null 2>&1'; then
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
    say "Checking Remote Control preconditions${C_DIM} (a few seconds)${C_RESET}"
    blockers="$(remote_blockers)"
    if [ -z "$blockers" ]; then
        skip "remote control preconditions look fine"
        return 0
    fi
    warn "Remote Control will not connect:"
    printf '%s\n' "$blockers" | sed 's/^/         - /' >&2
    return 1
}

# What is the session actually showing? screen can dump a detached window, which
# is the only way to see a Remote Control failure notice without attaching.
session_screen_dump() {
    local name="$1" tmp="/tmp/claude-session-$$.dump"
    as_user_t 15 "screen -S $(printf %q "$name") -X hardcopy $(printf %q "$tmp")" >/dev/null 2>&1
    sleep 0.5
    [ -r "$tmp" ] && { sed '/^[[:space:]]*$/d' "$tmp"; rm -f "$tmp"; }
}

# After starting a remote session, say whether it really connected.
verify_remote() {
    local name="$1" dump
    say "Waiting for Remote Control to connect${C_DIM} (a few seconds)${C_RESET}"
    vlog "sleeping 4s before reading the session screen"
    sleep 4
    dump="$(session_screen_dump "$name")"
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
    local log; log="$(session_log_of "$name")"
    warn "could not confirm Remote Control connected"
    if [ -s "$log" ]; then
        tail -8 "$log" | sed 's/\r$//' | sed '/^[[:space:]]*$/d' | sed 's/^/         /' >&2
    fi
    warn "  more detail: claude.sh doctor $name"
    return 1
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
    { sessions_header; printf '%-11s %-33s %s\n' "$sn" "$wd" autostart; } | sessions_write
    ok "migrated $LEGACY_CONF into $SESSIONS_CONF ('$sn' -> $wd)"
}

# ------------------------------------------------------------ screen sessions --
# screen sockets live in a per-user directory (/run/screen/S-<user>), so root
# cannot see a session belonging to $TARGET_USER. Every screen call has to be
# made as that user or the session looks like it does not exist.
screen_as_user() {
    if [ "$(id -un)" = "$TARGET_USER" ]; then
        screen "$@"
    elif have sudo; then
        sudo -u "$TARGET_USER" -H screen "$@"
    else
        su - "$TARGET_USER" -c "screen $(printf '%q ' "$@")"
    fi
}

# Match the session name as a literal string, not a regex: names are
# user-supplied and a '.', '+' or '*' in one would otherwise match the wrong
# thing — or nothing, silently starting a duplicate on every boot.
session_line_of() {
    screen_as_user -ls 2>/dev/null | awk -v want="$1" '
        match($1, /^[0-9]+\./) && substr($1, RSTART + RLENGTH) == want {
            sub(/^[[:space:]]+/, ""); print; exit
        }'
}

session_running() {
    have screen || return 1
    [ -n "$(session_line_of "$1")" ]
}

running_names() {
    screen_as_user -ls 2>/dev/null | awk 'match($1, /^[0-9]+\./) { print substr($1, RSTART + RLENGTH) }'
}

start_one() {
    local name="$1" dir
    dir="$(session_dir "$name")"
    [ -n "$dir" ] || { warn "'$name' is not registered — add it with: claude.sh add $name <dir>"; return 1; }
    if session_running "$name"; then skip "'$name' already running"; return 0; fi
    # Write the boot script if it is missing or stale. This used to die() when
    # missing, which exits the whole program — unpleasant from inside the menu,
    # and pointless when we can simply write the file.
    if [ ! -x "$BOOT_SCRIPT" ]; then
        warn "boot script missing at $BOOT_SCRIPT — writing it"
        write_boot_script
    elif [ "$(stub_version_of "$BOOT_SCRIPT")" != "$STUB_VERSION" ]; then
        warn "$BOOT_SCRIPT is from an older version and cannot start a named session — replacing it"
        write_boot_script
    fi
    [ -x "$BOOT_SCRIPT" ] || { warn "could not write $BOOT_SCRIPT"; return 1; }
    mkdir_for_user "$(dirname "$BOOT_LOG")"
    mkdir_for_user "$SESSION_LOG_DIR"
    : > "$(session_log_of "$name")" 2>/dev/null || true
    own "$SESSION_LOG_DIR"
    : >> "$BOOT_LOG" 2>/dev/null || true
    own "$(dirname "$BOOT_LOG")"
    local mode; mode="$(session_remote "$name")"
    case "$mode" in
        server)      say "Starting '$name' in $dir ${C_CYAN}(remote control, server mode)${C_RESET}" ;;
        interactive) say "Starting '$name' in $dir ${C_CYAN}(remote control, interactive)${C_RESET}" ;;
        *)           say "Starting '$name' in $dir" ;;
    esac
    if [ "$mode" != no ]; then
        remote_preflight || warn "starting anyway — fix the above and restart '$name'"
    fi
    vlog "running $BOOT_SCRIPT $name"
    as_user "CLAUDE_CMD=$(printf %q "$CLAUDE_CMD") $(printf %q "$BOOT_SCRIPT") $(printf %q "$name")" 2>&1 | tee -a "$BOOT_LOG"
    vlog "boot script returned; waiting for the session to appear"
    sleep 1
    if session_running "$name"; then
        ok "'$name' is up"
        [ "$mode" != no ] && verify_remote "$name"
        return 0
    fi
    local appeared log
    appeared="$(running_names | grep -vxF "$name" | tr '\n' ' ')"
    warn "'$name' did not come up"
    log="$(session_log_of "$name")"
    if [ -s "$log" ]; then
        warn "  it printed this before exiting:"
        tail -12 "$log" | sed 's/\r$//' | sed '/^[[:space:]]*$/d' | sed 's/^/         /' >&2
    else
        warn "  see $BOOT_LOG"
    fi
    [ -n "${appeared// /}" ] && warn "  note: these are running instead: ${appeared% }"
    return 1
}

stop_one() {
    local name="$1"
    if session_running "$name"; then
        screen_as_user -S "$name" -X quit >/dev/null 2>&1
        sleep 1
        if session_running "$name"; then warn "'$name' would not die"; return 1; fi
        ok "'$name' stopped"
    else
        skip "'$name' is not running"
    fi
}

restart_one() { stop_one "$1"; start_one "$1"; }

enter_one() {
    local name="$1"
    session_running "$name" || die "'$name' is not running."
    [ -t 0 ] || die "not a terminal — attach by hand with: screen -r $name"
    say "Attaching to '$name' — detach again with ${C_BOLD}Ctrl-a d${C_RESET}"
    if [ "$(id -un)" = "$TARGET_USER" ]; then
        exec screen -d -r "$name"
    elif have sudo; then
        exec sudo -u "$TARGET_USER" -H screen -d -r "$name"
    else
        exec su - "$TARGET_USER" -c "screen -d -r $(printf %q "$name")"
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

# ------------------------------------------------------------------ the table --
# Pad plain text first, then colourise, so escape sequences never shift columns.
print_table() {
    local n dir auto remote count=0 state pad r
    printf '\n  %-3s %-12s %-9s %-5s %-7s %s\n' '#' 'session' 'state' 'auto' 'remote' 'work directory'
    printf '  %s\n' "$(printf '%.0s-' {1..74})"
    while IFS="$TAB" read -r n dir auto remote; do
        [ -n "$n" ] || continue
        count=$((count + 1))
        if session_running "$n"; then printf -v pad '%-9s' running; state="${C_GREEN}${pad}${C_RESET}"
        else                          printf -v pad '%-9s' stopped; state="${C_DIM}${pad}${C_RESET}"; fi
        case "$remote" in
            server)      printf -v r '%-7s' server; r="${C_CYAN}${r}${C_RESET}" ;;
            interactive) printf -v r '%-7s' inter;  r="${C_CYAN}${r}${C_RESET}" ;;
            *)           printf -v r '%-7s' '-';    r="${C_DIM}${r}${C_RESET}" ;;
        esac
        printf '  %-3s %-12s %b %-5s %b %s\n' "$count" "$n" "$state" "$auto" "$r" "$dir"
    done < <(sessions_read)
    if [ "$count" -eq 0 ]; then
        printf '  %s\n' "${C_DIM}nothing registered yet — claude.sh add <name> <dir>${C_RESET}"
    fi
    # Sessions running that nobody registered: surface them rather than hide them.
    for r in $(running_names); do
        session_known "$r" || printf '  %-3s %-12s %-9s %-5s %-7s %s\n' '-' "$r" 'running' '-' '-' "${C_DIM}(not registered)${C_RESET}"
    done
    printf '\n'
}

nth_session() { sessions_read | awk -F'\t' -v i="$1" 'NR == i { print $1 }'; }

# The entries depend on the session's state: offering Enter for a stopped
# session put a call to die() — which exits the whole script — under the default
# keystroke, and Start/Stop/Restart are each meaningless in one of the two
# states. Build the list from what is actually possible.
manage_one() {
    local name="$1" choice rem running=0 i
    local -a labels=() actions=()
    rem="$(session_remote "$name")"
    session_running "$name" && running=1

    printf '\n%s  %s\n' "${C_BOLD}$name${C_RESET}" "${C_DIM}$(session_dir "$name")${C_RESET}"
    if [ "$running" = 1 ]; then printf '  %s\n' "$(session_line_of "$name")"; else printf '  %s\n' "not running"; fi
    case "$rem" in
        server)      printf '  remote control: %s\n\n' "on (server mode)" ;;
        interactive) printf '  remote control: %s\n\n' "on (interactive)" ;;
        *)           printf '  remote control: %s\n\n' "off" ;;
    esac

    if [ "$running" = 1 ]; then
        labels+=("Enter    attach to this session");        actions+=(enter)
        labels+=("Restart  stop it and start a fresh one"); actions+=(restart)
        labels+=("Stop     stop it");                       actions+=(stop)
    else
        labels+=("Start    start it");                      actions+=(start)
    fi
    # One entry for one setting, cycling off -> server -> interactive -> off,
    # labelled with where it will land rather than making you work it out.
    case "$rem" in
        no)          labels+=("Remote   off → server mode") ;;
        server)      labels+=("Remote   server mode → interactive") ;;
        interactive) labels+=("Remote   interactive → off") ;;
    esac
    actions+=(remote)
    labels+=("Back"); actions+=(back)

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
                no)          session_set_remote "$name" on ;;
                server)      session_set_remote "$name" interactive ;;
                interactive) session_set_remote "$name" off ;;
            esac ;;
        back)    return 0 ;;
    esac
}

main_menu() {
    local input name
    while true; do
        print_table
        printf '  %s\n' "${C_DIM}number = manage that one · n = new session · s = start all · r = restart all · x = stop all · q = quit${C_RESET}"
        input="$(ask "Choice: " q)"
        case "$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')" in
            q|quit|'') say "Nothing changed."; return 0 ;;
            n|new)     new_session_interactive ;;
            s|start)   printf '\n'; for_each start_one   "$(autostart_names | tr '\n' ' ')" ;;
            r|restart) printf '\n'; for_each restart_one "$(autostart_names | tr '\n' ' ')" ;;
            x|stop)    printf '\n'; for_each stop_one ;;
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
# Which contract does the stub on disk implement? Empty means it predates the
# marker, i.e. the single-session version.
session_log_of() { printf '%s\n' "$SESSION_LOG_DIR/$1.log"; }

stub_version_of() {
    sed -n 's/^# claude-session-boot stub-version: //p' "$1" 2>/dev/null | head -1
}

write_boot_script() {
    local dest="$BOOT_SCRIPT" tmp
    mkdir_for_user "$(dirname "$dest")"
    mkdir_for_user "$(dirname "$BOOT_LOG")"
    tmp="$(mktemp)"

    cat > "$tmp" <<-'BOOT'
	#!/usr/bin/env bash
	# claude-session-boot stub-version: 5
	#
	# claude-session-boot.sh — launch Claude Code sessions in detached screens.
	#
	#   claude-session-boot.sh          start every autostart session
	#   claude-session-boot.sh <name>   start just that one, autostart or not
	#
	# Written by claude.sh as a STUB. Everything between the EDIT markers is
	# yours. claude.sh will not overwrite this file once you have edited it; it
	# writes a .new file alongside instead.
	#
	# Run by hand, or automatically at boot via the @reboot crontab entry.

	set -uo pipefail

	CONF="${CLAUDE_SESSIONS_CONF:-$HOME/.config/claude-sessions.conf}"
	CLAUDE_CMD="${CLAUDE_CMD:-claude}"
	LOGDIR="${CLAUDE_SESSION_LOGDIR:-$HOME/.local/state/claude-sessions}"
	ONLY="${1:-}"

	# screen gained -Logfile in 4.06; without it we simply do not capture output.
	SCREEN_CAN_LOG=''
	_sv="$(screen --version 2>/dev/null | awk '{print $3}')"
	if [ -n "$_sv" ] && [ "$(printf '%s\n4.06.00\n' "$_sv" | sort -V | head -1)" = "4.06.00" ]; then
	    SCREEN_CAN_LOG=1
	fi

	export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
	log() { printf '%s %s\n' "$(date -Is)" "$*"; }

	# ---8<--- EDIT BELOW — your own pre-launch steps (stub) ---8<---
	# Cron fires @reboot before the network is necessarily up, so a short wait
	# and any repo or credential setup belongs here. Examples:
	#
	#   sleep 20
	#   docker compose -f "$HOME/work/compose.yaml" up -d
	#
	# Do NOT export ANTHROPIC_API_KEY here if any session is marked remote:
	# Remote Control needs a claude.ai login and refuses to start with an API
	# key in the environment.
	#
	# ---8<--- EDIT ABOVE ---8<---

	# Literal name match: a name containing '.' or '+' would break a regex and
	# start a duplicate session on every boot.
	running() {
	    screen -ls 2>/dev/null | awk -v want="$1" '
	        match($1, /^[0-9]+\./) && substr($1, RSTART + RLENGTH) == want { found = 1 }
	        END { exit !found }'
	}

	[ -r "$CONF" ] || { log "no session registry at $CONF"; exit 0; }

	awk '{ sub(/#.*/, "") }
	     NF >= 2 {
	         auto = "yes"; remote = "no"
	         for (i = 3; i <= NF; i++) {
	             if      ($i == "noautostart")        auto   = "no"
	             else if ($i == "autostart")          auto   = "yes"
	             else if ($i == "remote")             remote = "server"
	             else if ($i == "remote-interactive") remote = "interactive"
	             else if ($i == "local")              remote = "no"
	         }
	         print $1 "\t" $2 "\t" auto "\t" remote
	     }' "$CONF" |
	while IFS="$(printf '\t')" read -r name dir auto remote; do
	    [ -n "$name" ] || continue
	    if [ -n "$ONLY" ]; then
	        [ "$name" = "$ONLY" ] || continue
	    elif [ "$auto" != yes ]; then
	        log "skipping '$name' (noautostart)"
	        continue
	    fi
	    if running "$name"; then
	        log "'$name' already running; nothing to do"
	        continue
	    fi
	    mkdir -p "$dir"
	    mkdir -p "$LOGDIR"
	    case "$remote" in
	        server)
	            # Server mode: no local prompt, and it EXITS on failure instead
	            # of quietly degrading to an ordinary session.
	            log "starting '$name' in $dir (remote control, server mode)"
	            launch="$CLAUDE_CMD remote-control --name $(printf %q "$name")" ;;
	        interactive)
	            log "starting '$name' in $dir (remote control, interactive)"
	            launch="$CLAUDE_CMD --remote-control $(printf %q "$name")" ;;
	        *)
	            log "starting '$name' in $dir"
	            launch="$CLAUDE_CMD" ;;
	    esac
	    # Start screen FROM the work directory, not just the window inside it:
	    # the session daemon's cwd is what any new window (Ctrl-a c) inherits,
	    # and what you land in if the command exits.
	    if ! cd "$dir"; then
	        log "cannot enter $dir — skipping '$name'"
	        continue
	    fi
	    # Keep the window's output, so a session that dies immediately still
	    # leaves the reason behind. Without this it vanishes without a trace.
	    logfile="$LOGDIR/$name.log"
	    if [ -n "$SCREEN_CAN_LOG" ]; then
	        screen -L -Logfile "$logfile" -dmS "$name" bash -lc "cd $(printf %q "$dir") && exec $launch"
	    else
	        screen -dmS "$name" bash -lc "cd $(printf %q "$dir") && exec $launch"
	    fi
	done
	BOOT

    # A checksum of what we last wrote, so an untouched stub can be upgraded in
    # place instead of spawning a .new file on every change, while a stub you
    # have actually edited is still never overwritten.
    local stamp="$dest.sha256"
    _stub_sum() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
    _stub_record() { _stub_sum "$dest" > "$stamp" 2>/dev/null; own "$stamp"; }

    if [ ! -e "$dest" ]; then
        install -m 0755 "$tmp" "$dest"; rm -f "$tmp"; _stub_record
        ok "wrote $dest"
    elif cmp -s "$tmp" "$dest"; then
        rm -f "$tmp"; [ -r "$stamp" ] || _stub_record
        skip "$dest already current"
    elif [ -r "$stamp" ] && [ "$(_stub_sum "$dest")" = "$(cat "$stamp" 2>/dev/null)" ]; then
        install -m 0755 "$tmp" "$dest"; rm -f "$tmp"; _stub_record
        ok "updated $dest (it was unmodified since we wrote it)"
    elif [ "$(stub_version_of "$dest")" != "$STUB_VERSION" ] && grep -qs 'claude-session-boot' "$dest"; then
        # One of ours, but an older contract: it ignores the session name we
        # pass and starts whatever its own config says. Keeping it "safe" would
        # mean quietly starting the wrong session, so replace it and keep a
        # copy of whatever was there.
        local backup="$dest.bak"
        local n=1; while [ -e "$backup" ]; do backup="$dest.bak.$n"; n=$((n + 1)); done
        cp -p "$dest" "$backup" 2>/dev/null && own "$backup"
        install -m 0755 "$tmp" "$dest"; rm -f "$tmp"; _stub_record
        warn "replaced an incompatible boot script (stub-version '$(stub_version_of "$backup")', wanted $STUB_VERSION)"
        warn "  the old one ignored the session name and started whatever its own config said"
        ok "your previous copy is at $backup"
    else
        install -m 0755 "$tmp" "$dest.new"; rm -f "$tmp"
        warn "kept your $dest — newest stub written to $dest.new"
    fi
    chmod +x "$dest" 2>/dev/null || true
    own "$(dirname "$dest")"; own "$(dirname "$BOOT_LOG")"
}

crontab_get() { $SUDO crontab -u "$TARGET_USER" -l 2>/dev/null; }
crontab_put() { $SUDO crontab -u "$TARGET_USER" -; }

install_cron() {
    local line="@reboot $BOOT_SCRIPT >> $BOOT_LOG 2>&1 $CRON_MARKER"
    local current
    current="$(crontab_get)"
    if printf '%s\n' "$current" | grep -qxF "$line"; then
        skip "@reboot crontab entry already present"
        return 0
    fi
    if { printf '%s\n' "$current" | grep -vF "$CRON_MARKER" | grep -vF "$CRON_MARKER_LEGACY" | sed '/^$/d'; printf '%s\n' "$line"; } | crontab_put; then
        ok "installed @reboot crontab entry for $TARGET_USER"
    else
        warn "could not write crontab for $TARGET_USER"
    fi
}

remove_cron() {
    local current
    current="$(crontab_get)"
    if printf '%s\n' "$current" | grep -qF -e "$CRON_MARKER" -e "$CRON_MARKER_LEGACY"; then
        printf '%s\n' "$current" | grep -vF "$CRON_MARKER" | grep -vF "$CRON_MARKER_LEGACY" | sed '/^$/d' | crontab_put \
            && ok "removed @reboot crontab entry"
    else
        skip "no managed crontab entry to remove"
    fi
}

bootstrap_first_session() {
    [ "$(session_count)" -gt 0 ] && return 0
    local dir
    dir="$(ask "Working directory for your first session [$TARGET_HOME/work]: " "$TARGET_HOME/work")"
    session_add claude "${dir/#\~/$TARGET_HOME}" autostart
}

# ------------------------------------------------------------------ commands --
provision() {
    require_sudo
    ensure_home_dirs

    printf '\n%s\n\n' "${C_BOLD}Setting up Claude Code on $(hostname) for $TARGET_USER${C_RESET}"

    say "Installing what the sessions need"
    apt_ensure git git                       # git first, as everything wants it
    apt_ensure screen screen
    apt_ensure curl curl
    apt_ensure crontab cron || apt_ensure crontab cronie
    install_claude_code

    say "Setting up the sessions"
    migrate_legacy_config
    bootstrap_first_session
    write_boot_script
    install_cron

    printf '\n%s\n' "${C_GREEN}${C_BOLD}Ready.${C_RESET}"
}

status() {
    printf '%s\n' "${C_BOLD}claude sessions${C_RESET}"
    print_table
    printf '  %-14s %s\n' 'registry'    "$SESSIONS_CONF $([ -r "$SESSIONS_CONF" ] || echo '(missing)')"
    printf '  %-14s %s\n' 'boot script' "$BOOT_SCRIPT $([ -x "$BOOT_SCRIPT" ] || echo '(missing)')"
    printf '  %-14s %s\n' 'boot log'    "$BOOT_LOG"
    printf '  %-14s %s\n' 'crontab'     "$(crontab_get | grep -F -e "$CRON_MARKER" -e "$CRON_MARKER_LEGACY" || echo '(no @reboot entry)')"
    printf '  %-14s %s\n' 'claude'      "$(as_user_t 15 'claude --version' 2>/dev/null | head -1 || echo 'not installed')"
    if sessions_read | awk -F'\t' '$4 != "no" { found = 1 } END { exit !found }'; then
        printf '  %-14s %s\n' 'remote' "some sessions use Remote Control — see claude.ai/code"
        [ -n "${ANTHROPIC_API_KEY:-}" ] && warn "ANTHROPIC_API_KEY is set; Remote Control will refuse it"
    fi
}

# Everything you need to see when a remote session is not showing up.
doctor() {
    local only="${1:-}" n dir auto remote dump
    printf '%s\n\n' "${C_BOLD}claude.sh doctor${C_RESET}"

    printf '  %-22s %s\n' 'user'    "$TARGET_USER ($TARGET_HOME)"
    printf '  %-22s %s\n' 'claude'  "$(as_user_t 15 'claude --version' 2>/dev/null | head -1 || echo 'not installed')"
    if as_user_t 25 'claude auth status >/dev/null 2>&1'; then
        printf '  %-22s %s\n' 'claude.ai login' "${C_GREEN}signed in${C_RESET}"
    else
        printf '  %-22s %s\n' 'claude.ai login' "${C_RED}not signed in${C_RESET}  (run: claude auth login)"
    fi
    local v val
    for v in ANTHROPIC_API_KEY ANTHROPIC_BASE_URL CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX; do
        val="$(as_user "printf '%s' \"\${$v:-}\"" 2>/dev/null)"
        if [ -n "$val" ]; then
            printf '  %-22s %s\n' "$v" "${C_RED}set${C_RESET}  (Remote Control refuses this)"
        fi
    done

    printf '\n  %s\n' "${C_BOLD}Remote Control eligibility${C_RESET}"
    local blockers; blockers="$(remote_blockers)"
    if [ -z "$blockers" ]; then
        printf '    %s\n' "${C_GREEN}nothing blocking it${C_RESET}"
    else
        printf '%s\n' "$blockers" | sed "s/^/    ${C_RED}x${C_RESET} /"
    fi
    printf '\n  %s\n' "${C_DIM}claude doctor says:${C_RESET}"
    as_user_t 40 'claude doctor' 2>&1 | grep -iE 'remote|login|auth|version' | head -8 | sed 's/^/    /' \
        || printf '    %s\n' "(claude doctor produced nothing)"

    printf '\n  %s\n' "${C_BOLD}Sessions${C_RESET}"
    while IFS="$TAB" read -r n dir auto remote; do
        [ -n "$n" ] || continue
        [ -z "$only" ] || [ "$only" = "$n" ] || continue
        printf '    %-12s %-11s %s\n' "$n" "$([ "$remote" = no ] && echo local || echo "remote:$remote")" \
            "$(session_running "$n" && echo running || echo stopped)"
        if [ "$remote" != no ] && session_running "$n"; then
            dump="$(session_screen_dump "$n")"
            if printf '%s' "$dump" | grep -qi 'claude\.ai/code'; then
                printf '      %s %s\n' "${C_GREEN}connected${C_RESET}" "$(printf '%s' "$dump" | grep -io 'https://claude\.ai/code[^[:space:]]*' | head -1)"
            else
                printf '      %s\n' "${C_YELLOW}no session URL on screen — last lines:${C_RESET}"
                printf '%s\n' "$dump" | tail -6 | sed 's/^/        /'
            fi
        fi
        local slog; slog="$(session_log_of "$n")"
        if [ -s "$slog" ] && ! session_running "$n"; then
            printf '      %s\n' "${C_DIM}last output before it exited ($slog):${C_RESET}"
            tail -8 "$slog" | sed 's/\r$//' | sed '/^[[:space:]]*$/d' | sed 's/^/        /'
        fi
    done < <(sessions_read)
    printf '\n  %s\n' "${C_DIM}boot log: $BOOT_LOG${C_RESET}"
}

uninstall() {
    say "Removing the boot scaffolding (packages and the registry are left alone)"
    for_each stop_one
    remove_cron
    [ -e "$BOOT_SCRIPT" ] && { rm -f "$BOOT_SCRIPT" "$BOOT_SCRIPT.sha256"; ok "removed $BOOT_SCRIPT"; }
    warn "left $SESSIONS_CONF in place — delete it by hand if you want it gone"
}

usage() {
    cat <<-USAGE
	${C_BOLD}claude.sh${C_RESET} $VERSION — run Claude Code headlessly in detached screen sessions

	  bash <(curl -Ss https://raw.githubusercontent.com/mkolakowski/curl/main/claude.sh) [command]

	${C_BOLD}Commands${C_RESET}
	  (none)                    table of sessions; pick one, press n for a new
	                            one, or act on all of them
	  install                   install Claude Code and write the boot files
	  new                       register a session, prompting for each answer
	                            (including cloning a GitHub repo to work in)
	  add <name> <dir> [flags]  register a session in one line
	                            flags: --no-autostart, --remote
	  rm <name>                 unregister a session (does not stop it)
	  list                      print the table and exit
	  start [name...]           start the named sessions, or every autostart one
	  stop [name...]            stop the named sessions, or all of them
	  restart [name...]         stop and start again
	  enter [name]              attach; the name may be omitted if only one runs
	  remote <name> on|interactive|off
	                            on          server mode: claude remote-control
	                                        (no local prompt; drive it remotely)
	                            interactive claude --remote-control: a normal
	                                        session that is also reachable remotely
	  status                    table plus registry, cron and Claude Code state
	  doctor [name]             why a remote session is not connecting
	  uninstall                 remove the boot script and @reboot entry
	  version                   print the version and exit
	  -v, --verbose             trace what the script is doing, with timings
	  help                      this text

	${C_BOLD}Registry${C_RESET}  $SESSIONS_CONF
	  <name>  <work directory>  [autostart|noautostart] [remote|local]

	${C_BOLD}Remote Control${C_RESET}
	  A session marked remote launches as "$CLAUDE_CMD --remote-control <name>"
	  and appears at claude.ai/code and in the Claude mobile app, while still
	  running here against this filesystem. It needs a claude.ai login on a Pro,
	  Max, Team or Enterprise plan — API keys are not supported, so
	  ANTHROPIC_API_KEY and ANTHROPIC_BASE_URL must be unset. Sign in once with:
	  claude auth login

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
    [ $# -ge 2 ] || die "usage: claude.sh add <name> <dir> [--no-autostart] [--remote]"
    local name="$1" dir="$2" auto=autostart rem='' f
    shift 2
    for f in "$@"; do
        case "$f" in
            --no-autostart|noautostart) auto=noautostart ;;
            --autostart|autostart)      auto=autostart ;;
            --remote|remote)            rem=remote ;;
            --local|local)              rem='' ;;
            *) die "unknown flag '$f' (want --no-autostart or --remote)" ;;
        esac
    done
    session_add "$name" "$dir" "$auto" "$rem"
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
            if [ "$(session_count)" -eq 0 ] && [ ! -x "$BOOT_SCRIPT" ]; then
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
        remote)
            [ $# -ge 2 ] || die "usage: claude.sh remote <name> on|off"
            session_set_remote "$1" "$2" ;;
        start|boot)     if [ $# -gt 0 ]; then for_each start_one "$@"; else for_each start_one "$(autostart_names | tr '\n' ' ')"; fi ;;
        stop|kill)      for_each stop_one "$@" ;;
        restart)        if [ $# -gt 0 ]; then for_each restart_one "$@"; else for_each restart_one "$(autostart_names | tr '\n' ' ')"; fi ;;
        enter|attach)   if [ $# -gt 0 ]; then enter_one "$1"; else enter_default; fi ;;
        status|st)      status ;;
        doctor|diag)    doctor "${1:-}" ;;
        uninstall)      uninstall ;;
        help|-h|--help) usage ;;
        *)
            if session_known "$cmd"; then manage_one "$cmd"; else usage; die "unknown command '$cmd'."; fi ;;
    esac
}

main "$@"
