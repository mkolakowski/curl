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
readonly REPO_URL="https://github.com/mkolakowski/curl"
readonly CRON_MARKER="# claude-session-boot (managed by claude.sh)"
# Entries written by the older combined curl.sh, so upgrades replace rather
# than duplicate them.
readonly CRON_MARKER_LEGACY="# claude-session-boot (managed by curl.sh)"
readonly TAB=$'\t'

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

have() { command -v "$1" >/dev/null 2>&1; }

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
             "$TARGET_HOME/.local/share" "$TARGET_HOME/.local/state"; do
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
                 if      ($i == "noautostart") auto   = "no"
                 else if ($i == "autostart")   auto   = "yes"
                 else if ($i == "remote")      remote = "yes"
                 else if ($i == "local")       remote = "no"
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
        '#   <name>  <work directory>  [autostart|noautostart] [remote|local]' \
        '#' \
        '# autostart  started by the @reboot entry (the default)' \
        '# remote     launch with Claude Code Remote Control, so the session can' \
        '#            be driven from claude.ai/code and the Claude mobile app' \
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
              printf "%-12s%-34s%s%s\n", $1, $2, ($3 == "no" ? "noautostart" : "autostart"), ($4 == "yes" ? " remote" : "")
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
          function row(nm, dr, au, rm) { printf "%-12s%-34s%s%s\n", nm, dr, au, (rm != "" ? " remote" : "") }
          $1 == n { row(n, d, a, r); seen = 1; next }
          { row($1, $2, ($3 == "no" ? "noautostart" : "autostart"), ($4 == "yes" ? "remote" : "")) }
          END { if (!seen) row(n, d, a, r) }'
    } | sessions_write
    mkdir_for_user "$dir"
    ok "registered '$name' -> $dir ($auto${remote:+, remote})"
    [ -n "$remote" ] && remote_preflight
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
    [ "$on" = on ] && rem=remote || rem=''
    session_add "$name" "$(session_dir "$name")" "$auto" "$rem"
    if session_running "$name"; then
        warn "'$name' is running — restart it for this to take effect: claude.sh restart $name"
    fi
}

# Remote Control needs a claude.ai login, and an API key in the environment
# actively breaks it. Say so at the point the user opts in, not later.
remote_preflight() {
    say "Remote Control notes"
    printf '  %s\n' \
        "${C_DIM}sessions launch as: $CLAUDE_CMD --remote-control <name>${C_RESET}" \
        "${C_DIM}find them at claude.ai/code, or under Code in the Claude app${C_RESET}"
    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        warn "ANTHROPIC_API_KEY is set — Remote Control needs a claude.ai login and refuses API keys. Unset it."
    fi
    if [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
        warn "ANTHROPIC_BASE_URL is set — Remote Control only works against api.anthropic.com. Unset it."
    fi
    skip "sign in once with: claude auth login   (Pro, Max, Team or Enterprise plan)"
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
    { sessions_header; printf '%-12s%-34s%s\n' "$sn" "$wd" autostart; } | sessions_write
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
    [ -x "$BOOT_SCRIPT" ] || die "boot script missing at $BOOT_SCRIPT — run 'claude.sh install' first."
    mkdir_for_user "$(dirname "$BOOT_LOG")"
    : >> "$BOOT_LOG" 2>/dev/null || true
    own "$(dirname "$BOOT_LOG")"
    if [ "$(session_remote "$name")" = yes ]; then
        say "Starting '$name' in $dir ${C_CYAN}(remote control)${C_RESET}"
    else
        say "Starting '$name' in $dir"
    fi
    as_user "CLAUDE_CMD=$(printf %q "$CLAUDE_CMD") $(printf %q "$BOOT_SCRIPT") $(printf %q "$name")" 2>&1 | tee -a "$BOOT_LOG"
    sleep 1
    if session_running "$name"; then
        ok "'$name' is up"
        [ "$(session_remote "$name")" = yes ] && skip "find it at claude.ai/code, or under Code in the Claude app"
        return 0
    fi
    warn "'$name' did not come up — see $BOOT_LOG"
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
        if [ "$remote" = yes ]; then printf -v r '%-7s' yes; r="${C_CYAN}${r}${C_RESET}"
        else                         printf -v r '%-7s' '-';  r="${C_DIM}${r}${C_RESET}"; fi
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

manage_one() {
    local name="$1" choice rem
    rem="$(session_remote "$name")"
    printf '\n%s  %s\n' "${C_BOLD}$name${C_RESET}" "${C_DIM}$(session_dir "$name")${C_RESET}"
    if session_running "$name"; then printf '  %s\n' "$(session_line_of "$name")"; else printf '  %s\n' "not running"; fi
    printf '  remote control: %s\n\n' "$([ "$rem" = yes ] && echo on || echo off)"
    cat <<-MENU
	  1) Enter    attach to this session
	  2) Restart  stop it and start a fresh one
	  3) Stop     stop it
	  4) Start    start it
	  5) Remote   turn remote control $([ "$rem" = yes ] && echo off || echo on)
	  6) Back
	MENU
    choice="$(ask "Choice [1]: " 1)"
    printf '\n'
    case "$choice" in
        1|''|e|enter) enter_one "$name" ;;
        2|r|restart)  restart_one "$name" ;;
        3|s|stop)     stop_one "$name" ;;
        4|start)      start_one "$name" ;;
        5|remote)     if [ "$rem" = yes ]; then session_set_remote "$name" off; else session_set_remote "$name" on; fi ;;
        6|b|back|q)   return 0 ;;
        *)            warn "unrecognised choice '$choice'" ;;
    esac
}

main_menu() {
    local input name
    while true; do
        print_table
        printf '  %s\n' "${C_DIM}number = manage that one · s = start all · r = restart all · x = stop all · q = quit${C_RESET}"
        input="$(ask "Choice: " q)"
        case "$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')" in
            q|quit|'') say "Nothing changed."; return 0 ;;
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
        skip "claude code already installed ($(as_user 'timeout 10 claude --version' 2>/dev/null | head -1))"
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
write_boot_script() {
    local dest="$BOOT_SCRIPT" tmp
    mkdir_for_user "$(dirname "$dest")"
    mkdir_for_user "$(dirname "$BOOT_LOG")"
    tmp="$(mktemp)"

    cat > "$tmp" <<-'BOOT'
	#!/usr/bin/env bash
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
	ONLY="${1:-}"

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
	             if      ($i == "noautostart") auto   = "no"
	             else if ($i == "autostart")   auto   = "yes"
	             else if ($i == "remote")      remote = "yes"
	             else if ($i == "local")       remote = "no"
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
	    if [ "$remote" = yes ]; then
	        log "starting '$name' in $dir (remote control)"
	        launch="$CLAUDE_CMD --remote-control $(printf %q "$name")"
	    else
	        log "starting '$name' in $dir"
	        launch="$CLAUDE_CMD"
	    fi
	    screen -dmS "$name" bash -lc "cd $(printf %q "$dir") && exec $launch"
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
    printf '  %-14s %s\n' 'claude'      "$(as_user 'timeout 10 claude --version' 2>/dev/null | head -1 || echo 'not installed')"
    if sessions_read | awk -F'\t' '$4 == "yes" { found = 1 } END { exit !found }'; then
        printf '  %-14s %s\n' 'remote' "some sessions use Remote Control — see claude.ai/code"
        [ -n "${ANTHROPIC_API_KEY:-}" ] && warn "ANTHROPIC_API_KEY is set; Remote Control will refuse it"
    fi
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
	${C_BOLD}claude.sh${C_RESET} — run Claude Code headlessly in detached screen sessions

	  bash <(curl -Ss https://raw.githubusercontent.com/mkolakowski/curl/main/claude.sh) [command]

	${C_BOLD}Commands${C_RESET}
	  (none)                    table of sessions, then pick one or act on all
	  install                   install Claude Code and write the boot files
	  add <name> <dir> [flags]  register a session
	                            flags: --no-autostart, --remote
	  rm <name>                 unregister a session (does not stop it)
	  list                      print the table and exit
	  start [name...]           start the named sessions, or every autostart one
	  stop [name...]            stop the named sessions, or all of them
	  restart [name...]         stop and start again
	  enter [name]              attach; the name may be omitted if only one runs
	  remote <name> on|off      turn Claude Code Remote Control on or off
	  status                    table plus registry, cron and Claude Code state
	  uninstall                 remove the boot script and @reboot entry
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
    migrate_legacy_config
    local cmd="${1:-}"; [ $# -gt 0 ] && shift
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
        rm|remove)      [ $# -ge 1 ] || die "usage: claude.sh rm <name>"; session_remove "$1" ;;
        list|ls)        print_table ;;
        remote)
            [ $# -ge 2 ] || die "usage: claude.sh remote <name> on|off"
            case "$2" in on|off) session_set_remote "$1" "$2" ;; *) die "usage: claude.sh remote <name> on|off" ;; esac ;;
        start|boot)     if [ $# -gt 0 ]; then for_each start_one "$@"; else for_each start_one "$(autostart_names | tr '\n' ' ')"; fi ;;
        stop|kill)      for_each stop_one "$@" ;;
        restart)        if [ $# -gt 0 ]; then for_each restart_one "$@"; else for_each restart_one "$(autostart_names | tr '\n' ' ')"; fi ;;
        enter|attach)   if [ $# -gt 0 ]; then enter_one "$1"; else enter_default; fi ;;
        status|st)      status ;;
        uninstall)      uninstall ;;
        help|-h|--help) usage ;;
        *)
            if session_known "$cmd"; then manage_one "$cmd"; else usage; die "unknown command '$cmd'."; fi ;;
    esac
}

main "$@"
