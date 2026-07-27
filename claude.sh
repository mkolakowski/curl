#!/usr/bin/env bash
#
# claude.sh — run Claude Code headlessly in a detached screen session.
#
#   bash <(curl -Ss https://raw.githubusercontent.com/mkolakowski/curl/main/claude.sh) [command]
#
# With no command:
#   * if a Claude Code screen session is already running -> Enter / Restart / Stop menu
#   * otherwise -> install what it needs, then start the session
#
# This script only handles Claude Code and its session. For everything else
# (Docker, Tailscale, btop, ...) use curl.sh in the same repo.
#
# Config (env var, or ~/.config/claude-session.env):
#   WORK_DIR      directory Claude Code is launched in   (default: $HOME/work)
#   SESSION_NAME  screen session name                    (default: claude)
#   CLAUDE_CMD    command used to launch Claude Code     (default: claude)
#   ASSUME_YES=1  never prompt; take every default

set -uo pipefail

# ---------------------------------------------------------------- constants --
readonly REPO_URL="https://github.com/mkolakowski/curl"
readonly CRON_MARKER="# claude-session-boot (managed by claude.sh)"
# Entries written by the older combined curl.sh, so upgrades replace rather
# than duplicate them.
readonly CRON_MARKER_LEGACY="# claude-session-boot (managed by curl.sh)"

# ------------------------------------------------------------------ plumbing --
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
    C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''
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
CONFIG_FILE="${CLAUDE_SESSION_CONFIG:-$TARGET_HOME/.config/claude-session.env}"
BOOT_SCRIPT="$TARGET_HOME/.local/bin/claude-session-boot.sh"
BOOT_LOG="$TARGET_HOME/.local/state/claude-session-boot.log"

# Environment beats the config file; the config file beats the built-in default.
_env_work_dir="${WORK_DIR:-}"
_env_session="${SESSION_NAME:-}"
_env_cmd="${CLAUDE_CMD:-}"

# shellcheck source=/dev/null
[ -r "$CONFIG_FILE" ] && . "$CONFIG_FILE"

WORK_DIR="${_env_work_dir:-${WORK_DIR:-$TARGET_HOME/work}}"
SESSION_NAME="${_env_session:-${SESSION_NAME:-claude}}"
CLAUDE_CMD="${_env_cmd:-${CLAUDE_CMD:-claude}}"

# ------------------------------------------------------------ screen session --
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

# Match the session name as a literal string, not a regex: SESSION_NAME is
# user-supplied and a '.', '+' or '*' in it would otherwise match the wrong
# thing — or nothing, silently starting a second session on every boot.
session_line() {
    screen_as_user -ls 2>/dev/null | awk -v want="$SESSION_NAME" '
        match($1, /^[0-9]+\./) && substr($1, RSTART + RLENGTH) == want {
            sub(/^[[:space:]]+/, ""); print; exit
        }'
}

session_exists() {
    have screen || return 1
    [ -n "$(session_line)" ]
}

session_start() {
    [ -x "$BOOT_SCRIPT" ] || die "boot script missing at $BOOT_SCRIPT — run 'claude.sh install' first."
    mkdir -p "$(dirname "$BOOT_LOG")"
    # Create and hand over the log before writing to it: started as root, the
    # tee below would otherwise leave a root-owned log that later runs as
    # $TARGET_USER (including the @reboot cron job) cannot append to.
    : >> "$BOOT_LOG" 2>/dev/null || true
    own "$(dirname "$BOOT_LOG")"
    say "Starting session '$SESSION_NAME' in $WORK_DIR"
    # Hand the resolved settings down so the boot script agrees with what we
    # just printed, even when they came from the environment rather than config.
    local env_prefix
    env_prefix="WORK_DIR=$(printf %q "$WORK_DIR") SESSION_NAME=$(printf %q "$SESSION_NAME") CLAUDE_CMD=$(printf %q "$CLAUDE_CMD")"
    if as_user "$env_prefix $(printf %q "$BOOT_SCRIPT")" 2>&1 | tee -a "$BOOT_LOG"; then
        sleep 1
        if session_exists; then ok "session '$SESSION_NAME' is up"
        else warn "session did not come up — see $BOOT_LOG"; fi
    else
        warn "boot script exited non-zero — see $BOOT_LOG"
    fi
}

session_stop() {
    if session_exists; then
        screen_as_user -S "$SESSION_NAME" -X quit >/dev/null 2>&1
        sleep 1
        if session_exists; then warn "session '$SESSION_NAME' would not die"
        else ok "session '$SESSION_NAME' stopped"; fi
    else
        skip "no session named '$SESSION_NAME'"
    fi
}

session_enter() {
    session_exists || die "no session named '$SESSION_NAME' to attach to."
    [ -t 0 ] || die "not a terminal — attach by hand with: screen -r $SESSION_NAME"
    say "Attaching — detach again with ${C_BOLD}Ctrl-a d${C_RESET}"
    if [ "$(id -un)" = "$TARGET_USER" ]; then
        exec screen -d -r "$SESSION_NAME"
    elif have sudo; then
        exec sudo -u "$TARGET_USER" -H screen -d -r "$SESSION_NAME"
    else
        exec su - "$TARGET_USER" -c "screen -d -r $(printf %q "$SESSION_NAME")"
    fi
}

session_menu() {
    printf '\n%s\n' "${C_BOLD}A Claude Code session is already running.${C_RESET}"
    printf '  %-9s %s\n' 'session' "$(session_line)"
    printf '  %-9s %s\n' 'workdir' "$WORK_DIR"
    printf '  %-9s %s\n\n' 'boot' "$BOOT_SCRIPT"
    cat <<-MENU
	  1) Enter    attach to the running session
	  2) Restart  stop it and start a fresh one
	  3) Stop     stop it and exit
	  4) Install  skip the menu, re-run the setup
	  5) Quit     leave everything alone
	MENU
    local choice
    choice="$(ask "Choice [1]: " 1)"
    printf '\n'
    case "$choice" in
        1|''|e|enter|a|attach) session_enter ;;
        2|r|restart)           session_stop; session_start ;;
        3|s|stop)              session_stop ;;
        4|i|install)           provision; session_start ;;
        5|q|quit)              say "Nothing changed." ;;
        *)                     die "unrecognised choice '$choice'." ;;
    esac
}

# ------------------------------------------------------------- install steps --
apt_ensure() {
    # apt_ensure <binary> <package> [package...]
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

    # The native installer drops the launcher in ~/.local/bin.
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
write_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")"
    if [ -r "$CONFIG_FILE" ]; then
        skip "config already at $CONFIG_FILE"
        return 0
    fi
    cat > "$CONFIG_FILE" <<-CONF
	# Read by claude-session-boot.sh and claude.sh. Edit freely.
	WORK_DIR=$WORK_DIR
	SESSION_NAME=$SESSION_NAME
	CLAUDE_CMD=$CLAUDE_CMD
	CONF
    own "$(dirname "$CONFIG_FILE")"
    ok "wrote $CONFIG_FILE"
}

write_boot_script() {
    local dest="$BOOT_SCRIPT" tmp
    mkdir -p "$(dirname "$dest")" "$(dirname "$BOOT_LOG")" "$WORK_DIR"
    tmp="$(mktemp)"

    cat > "$tmp" <<-'BOOT'
	#!/usr/bin/env bash
	#
	# claude-session-boot.sh — launch Claude Code in a detached screen session.
	#
	# Written by claude.sh as a STUB. Everything between the EDIT markers is
	# yours: put whatever needs to happen before Claude Code starts in there.
	# claude.sh will not overwrite this file once it exists (it writes a .new
	# file alongside instead).
	#
	# Run by hand, or automatically at boot via the @reboot crontab entry.

	set -uo pipefail

	CONFIG_FILE="${CLAUDE_SESSION_CONFIG:-$HOME/.config/claude-session.env}"

	# Environment beats the config file; the config file beats the default.
	_env_wd="${WORK_DIR:-}"; _env_sn="${SESSION_NAME:-}"; _env_cc="${CLAUDE_CMD:-}"
	# shellcheck source=/dev/null
	[ -r "$CONFIG_FILE" ] && . "$CONFIG_FILE"

	WORK_DIR="${_env_wd:-${WORK_DIR:-$HOME/work}}"
	SESSION_NAME="${_env_sn:-${SESSION_NAME:-claude}}"
	CLAUDE_CMD="${_env_cc:-${CLAUDE_CMD:-claude}}"

	export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
	log() { printf '%s %s\n' "$(date -Is)" "$*"; }

	# ---8<--- EDIT BELOW — your own pre-launch steps (stub) ---8<---
	# Cron fires @reboot before the network is necessarily up, so a short wait and
	# any repo/credential setup belongs here. Examples:
	#
	#   sleep 20
	#   git -C "$WORK_DIR" pull --ff-only
	#   export ANTHROPIC_API_KEY="$(cat "$HOME/.config/anthropic.key")"
	#   docker compose -f "$WORK_DIR/compose.yaml" up -d
	#
	# ---8<--- EDIT ABOVE ---8<---

	mkdir -p "$WORK_DIR"

	# Literal name match — see the note in claude.sh; a regex here would let a
	# name containing '.' or '+' start a duplicate session on every boot.
	if screen -ls 2>/dev/null | awk -v want="$SESSION_NAME" '
	       match($1, /^[0-9]+\./) && substr($1, RSTART + RLENGTH) == want { found = 1 }
	       END { exit !found }'; then
	    log "session '$SESSION_NAME' already running; nothing to do"
	    exit 0
	fi

	log "starting '$SESSION_NAME' in $WORK_DIR"
	screen -dmS "$SESSION_NAME" bash -lc "cd $(printf %q "$WORK_DIR") && exec $CLAUDE_CMD"
	log "attach with: screen -r $SESSION_NAME"
	BOOT

    if [ ! -e "$dest" ]; then
        install -m 0755 "$tmp" "$dest"
        rm -f "$tmp"
        ok "wrote $dest"
    elif cmp -s "$tmp" "$dest"; then
        rm -f "$tmp"
        skip "$dest already current"
    else
        install -m 0755 "$tmp" "$dest.new"
        rm -f "$tmp"
        warn "kept your $dest — newest stub written to $dest.new"
    fi
    chmod +x "$dest" 2>/dev/null || true
    own "$(dirname "$dest")"; own "$(dirname "$BOOT_LOG")"; own "$WORK_DIR"
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

choose_work_dir() {
    [ -n "$_env_work_dir" ] && return 0     # explicitly set via env — don't ask
    [ -r "$CONFIG_FILE" ]   && return 0     # already configured — don't ask
    local answer
    answer="$(ask "Working directory for Claude Code [$WORK_DIR]: " "$WORK_DIR")"
    WORK_DIR="${answer/#\~/$TARGET_HOME}"
}

# ------------------------------------------------------------------ commands --
provision() {
    require_sudo
    choose_work_dir

    printf '\n%s\n' "${C_BOLD}Setting up Claude Code on $(hostname) for $TARGET_USER${C_RESET}"
    printf '%s\n\n' "${C_DIM}work dir $WORK_DIR · session $SESSION_NAME${C_RESET}"

    say "Installing what the session needs"
    apt_ensure git git                       # git first, as everything wants it
    apt_ensure screen screen
    apt_ensure curl curl
    apt_ensure crontab cron || apt_ensure crontab cronie
    install_claude_code

    say "Setting up the boot session"
    write_config
    write_boot_script
    install_cron

    printf '\n%s\n' "${C_GREEN}${C_BOLD}Claude Code session ready.${C_RESET}"
}

status() {
    printf '%s\n' "${C_BOLD}claude session status${C_RESET}"
    printf '  %-14s %s\n' 'work dir'    "$WORK_DIR"
    printf '  %-14s %s\n' 'session'     "$SESSION_NAME"
    printf '  %-14s %s\n' 'claude cmd'  "$CLAUDE_CMD"
    printf '  %-14s %s\n' 'config'      "$CONFIG_FILE $([ -r "$CONFIG_FILE" ] || echo '(missing)')"
    printf '  %-14s %s\n' 'boot script' "$BOOT_SCRIPT $([ -x "$BOOT_SCRIPT" ] || echo '(missing)')"
    printf '  %-14s %s\n' 'boot log'    "$BOOT_LOG"
    printf '  %-14s %s\n' 'crontab'     "$(crontab_get | grep -F -e "$CRON_MARKER" -e "$CRON_MARKER_LEGACY" || echo '(no @reboot entry)')"
    printf '  %-14s %s\n' 'claude'      "$(as_user 'timeout 10 claude --version' 2>/dev/null | head -1 || echo 'not installed')"
    printf '  %-14s %s\n' 'running'     "$(session_exists && session_line || echo 'no')"
}

uninstall() {
    say "Removing the boot session scaffolding (packages are left alone)"
    session_stop
    remove_cron
    [ -e "$BOOT_SCRIPT" ] && { rm -f "$BOOT_SCRIPT"; ok "removed $BOOT_SCRIPT"; }
    warn "left $CONFIG_FILE in place — delete it by hand if you want it gone"
}

usage() {
    cat <<-USAGE
	${C_BOLD}claude.sh${C_RESET} — run Claude Code headlessly in a detached screen session

	  bash <(curl -Ss https://raw.githubusercontent.com/mkolakowski/curl/main/claude.sh) [command]

	${C_BOLD}Commands${C_RESET}
	  (none)      menu if a session is running, otherwise install + start
	  install     install Claude Code and write the boot session files
	  start       launch the session via the boot script
	  enter       attach to the running session
	  restart     stop and relaunch the session
	  stop        stop the session
	  status      show config and session state
	  uninstall   remove the boot script and @reboot entry
	  help        this text

	${C_BOLD}Config${C_RESET} (env var, or $CONFIG_FILE)
	  WORK_DIR      directory Claude Code runs in    (now: $WORK_DIR)
	  SESSION_NAME  screen session name              (now: $SESSION_NAME)
	  CLAUDE_CMD    launch command                   (now: $CLAUDE_CMD)
	  ASSUME_YES=1  never prompt, take the defaults

	For Docker, Tailscale, btop and friends, use curl.sh in the same repo.
	  $REPO_URL
	USAGE
}

main() {
    case "${1:-}" in
        ''|default)
            if session_exists; then session_menu; else provision; session_start; fi ;;
        install|setup)       provision ;;
        start|boot)          session_start ;;
        enter|attach)        session_enter ;;
        restart)             session_stop; session_start ;;
        stop|kill)           session_stop ;;
        status|st)           status ;;
        uninstall)           uninstall ;;
        help|-h|--help)      usage ;;
        *)                   usage; die "unknown command '$1'." ;;
    esac
}

main "$@"
