#!/usr/bin/env bash
#
# curl.sh — bootstrap an Ubuntu box for headless Claude Code work.
#
#   bash <(curl -Ss https://raw.githubusercontent.com/mkolakowski/curl/main/curl.sh) [command]
#
# With no command:
#   * if a Claude Code screen session is already running -> Enter / Restart / Stop menu
#   * otherwise -> provision the machine, then start the session
#
# Every install step is idempotent, so re-running is cheap and safe.
#
# Config (env var, or ~/.config/claude-session.env):
#   WORK_DIR      directory Claude Code is launched in   (default: $HOME/work)
#   SESSION_NAME  screen session name                    (default: claude)
#   CLAUDE_CMD    command used to launch Claude Code     (default: claude)
#   ASSUME_YES=1  never prompt; take every default
#
# Legacy scripts live in archive/.

set -uo pipefail

# ---------------------------------------------------------------- constants --
readonly REPO_URL="https://github.com/mkolakowski/curl"
readonly CRON_MARKER="# claude-session-boot (managed by curl.sh)"

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
if [ "$(id -u)" -eq 0 ]; then SUDO=''; else SUDO='sudo'; fi

TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)"
[ -n "$TARGET_HOME" ] || TARGET_HOME="$HOME"

# Run a command as the human who invoked us (not as root), with a login shell
# so ~/.local/bin ends up on PATH.
as_user() {
    if [ "$(id -un)" = "$TARGET_USER" ]; then
        bash -lc "$*"
    else
        $SUDO -u "$TARGET_USER" -H bash -lc "$*"
    fi
}

# Anything we create in $TARGET_HOME while running under sudo must not stay
# root-owned, or the session (and Claude Code) can't write to it later.
own() { [ -e "$1" ] && $SUDO chown -R "$TARGET_USER" "$1" 2>/dev/null; return 0; }

require_sudo() {
    [ -z "$SUDO" ] && return 0
    have sudo || die "sudo is not installed and we are not root."
    $SUDO -v || die "sudo authentication failed."
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
session_exists() {
    have screen || return 1
    screen -ls 2>/dev/null | grep -qE "^[[:space:]]*[0-9]+\.${SESSION_NAME}[[:space:]]"
}

session_line() {
    screen -ls 2>/dev/null | grep -E "^[[:space:]]*[0-9]+\.${SESSION_NAME}[[:space:]]" | head -1 | sed 's/^[[:space:]]*//'
}

session_start() {
    [ -x "$BOOT_SCRIPT" ] || die "boot script missing at $BOOT_SCRIPT — run '$0 install' first."
    mkdir -p "$(dirname "$BOOT_LOG")"
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
        screen -S "$SESSION_NAME" -X quit >/dev/null 2>&1
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
    exec screen -d -r "$SESSION_NAME"
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
	  4) Install  skip the menu, re-run provisioning
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
apt_update_upgrade() {
    say "Updating Ubuntu"
    export DEBIAN_FRONTEND=noninteractive
    $SUDO apt-get update -qq || { warn "apt-get update failed"; return 1; }
    $SUDO apt-get upgrade -y -qq || { warn "apt-get upgrade failed"; return 1; }
    $SUDO apt-get autoremove -y -qq >/dev/null 2>&1
    ok "system packages up to date"
}

apt_ensure() {
    # apt_ensure <binary> <package> [package...]
    local bin="$1"; shift
    if have "$bin"; then skip "$bin already installed ($("$bin" --version 2>/dev/null | head -1))"; return 0; fi
    say "Installing $*"
    if DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq "$@"; then
        ok "$bin installed"
    else
        warn "could not install $* via apt"; return 1
    fi
}

install_btop() {
    if have btop; then skip "btop already installed"; return 0; fi
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
        apt_ensure curl curl >/dev/null 2>&1
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

install_claude_code() {
    if as_user 'command -v claude >/dev/null 2>&1'; then
        skip "claude code already installed ($(as_user 'claude --version' 2>/dev/null | head -1))"
        return 0
    fi
    say "Installing Claude Code"
    as_user 'curl -fsSL https://claude.ai/install.sh | bash' \
        || { warn "Claude Code install failed"; return 1; }

    # The native installer drops the launcher in ~/.local/bin.
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
write_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")"
    if [ -r "$CONFIG_FILE" ]; then
        skip "config already at $CONFIG_FILE"
        return 0
    fi
    cat > "$CONFIG_FILE" <<-CONF
	# Read by claude-session-boot.sh and curl.sh. Edit freely.
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
	# Written by curl.sh as a STUB. Everything between the EDIT markers is yours:
	# put whatever needs to happen before Claude Code starts in there. curl.sh will
	# not overwrite this file once it exists (it writes a .new alongside instead).
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

	if screen -ls 2>/dev/null | grep -qE "^[[:space:]]*[0-9]+\.${SESSION_NAME}[[:space:]]"; then
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
    if { printf '%s\n' "$current" | grep -vF "$CRON_MARKER" | sed '/^$/d'; printf '%s\n' "$line"; } | crontab_put; then
        ok "installed @reboot crontab entry for $TARGET_USER"
    else
        warn "could not write crontab for $TARGET_USER"
    fi
}

remove_cron() {
    local current
    current="$(crontab_get)"
    if printf '%s\n' "$current" | grep -qF "$CRON_MARKER"; then
        printf '%s\n' "$current" | grep -vF "$CRON_MARKER" | sed '/^$/d' | crontab_put \
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

    printf '\n%s\n' "${C_BOLD}Provisioning $(hostname) for $TARGET_USER${C_RESET}"
    printf '%s\n\n' "${C_DIM}work dir $WORK_DIR · session $SESSION_NAME${C_RESET}"

    apt_update_upgrade
    apt_ensure git git                       # git first, as promised
    apt_ensure screen screen
    apt_ensure curl curl
    apt_ensure crontab cron || apt_ensure crontab cronie
    install_btop
    install_docker
    install_tailscale
    install_claude_code

    say "Setting up the boot session"
    write_config
    write_boot_script
    install_cron

    printf '\n%s\n' "${C_GREEN}${C_BOLD}Provisioning complete.${C_RESET}"
}

status() {
    printf '%s\n' "${C_BOLD}claude-session status${C_RESET}"
    printf '  %-14s %s\n' 'work dir'   "$WORK_DIR"
    printf '  %-14s %s\n' 'session'    "$SESSION_NAME"
    printf '  %-14s %s\n' 'claude cmd' "$CLAUDE_CMD"
    printf '  %-14s %s\n' 'config'     "$CONFIG_FILE $([ -r "$CONFIG_FILE" ] || echo '(missing)')"
    printf '  %-14s %s\n' 'boot script' "$BOOT_SCRIPT $([ -x "$BOOT_SCRIPT" ] || echo '(missing)')"
    printf '  %-14s %s\n' 'boot log'   "$BOOT_LOG"
    printf '  %-14s %s\n' 'crontab'    "$(crontab_get | grep -F "$CRON_MARKER" || echo '(no @reboot entry)')"
    printf '  %-14s %s\n' 'running'    "$(session_exists && session_line || echo 'no')"
    printf '\n  %-14s\n' 'tools'
    local t
    for t in git screen btop docker tailscale claude; do
        if have "$t" || as_user "command -v $t >/dev/null 2>&1"; then
            printf '    %-10s %s\n' "$t" "${C_GREEN}present${C_RESET}"
        else
            printf '    %-10s %s\n' "$t" "${C_RED}missing${C_RESET}"
        fi
    done
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
	${C_BOLD}curl.sh${C_RESET} — provision Ubuntu for headless Claude Code work

	  bash <(curl -Ss https://raw.githubusercontent.com/mkolakowski/curl/main/curl.sh) [command]

	${C_BOLD}Commands${C_RESET}
	  (none)      menu if a session is running, otherwise install + start
	  install     run every provisioning step (idempotent)
	  start       launch the session via the boot script
	  enter       attach to the running session
	  restart     stop and relaunch the session
	  stop        stop the session
	  status      show config, tooling and session state
	  update      apt update + upgrade only
	  reboot      reboot the machine
	  uninstall   remove the boot script and @reboot entry
	  help        this text

	${C_BOLD}Config${C_RESET} (env var, or $CONFIG_FILE)
	  WORK_DIR      directory Claude Code runs in    (now: $WORK_DIR)
	  SESSION_NAME  screen session name              (now: $SESSION_NAME)
	  CLAUDE_CMD    launch command                   (now: $CLAUDE_CMD)
	  ASSUME_YES=1  never prompt, take the defaults

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
        update)              require_sudo; apt_update_upgrade ;;
        reboot)              say "Rebooting…"; $SUDO reboot ;;
        uninstall)           uninstall ;;
        help|-h|--help)      usage ;;
        *)                   usage; die "unknown command '$1'." ;;
    esac
}

main "$@"
