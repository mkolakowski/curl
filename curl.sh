#!/usr/bin/env bash
#
# curl.sh — pick the tools you want on an Ubuntu box and install them.
#
#   bash <(curl -Ss https://raw.githubusercontent.com/mkolakowski/curl/main/curl.sh)
#
# With no arguments you get a checklist: toggle things on, hit Enter, done.
# Or name them directly:
#
#   bash <(curl -Ss .../curl.sh) install git docker
#   bash <(curl -Ss .../curl.sh) install all
#
# Every install is idempotent — anything already present is reported and
# skipped, so re-running is cheap and safe.
#
# Claude Code and its boot session live in claude.sh; picking "claude" here
# just hands off to that script.

set -uo pipefail

# ---------------------------------------------------------------- constants --
readonly REPO_URL="https://github.com/mkolakowski/curl"
RAW_BASE="${CURL_SH_RAW_BASE:-https://raw.githubusercontent.com/mkolakowski/curl/main}"

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

require_sudo() {
    [ -z "$SUDO" ] && return 0
    have sudo || die "sudo is not installed and we are not root."
    # `sudo -v` prompts for a password even where NOPASSWD applies, which fails
    # outright when there is no tty. Probe non-interactively first: if that
    # succeeds we are either NOPASSWD or already authenticated.
    sudo -n true 2>/dev/null && return 0
    sudo -v || die "sudo authentication failed."
}

# ---------------------------------------------------------------- the catalog --
# Order matters: this is the order things get installed in, so git comes early
# and the Claude Code hand-off comes last.
PKG_KEYS=(update    git     screen  btop     docker                          tailscale       claude)
PKG_BLURB=(
    "apt update && apt full-upgrade"
    "version control"
    "detachable terminal sessions"
    "resource monitor"
    "Docker Engine + Compose plugin"
    "mesh VPN"
    "Claude Code + boot session (runs claude.sh)"
)

# check_<key> prints a short state string; empty output means "not installed".
check_update()    { printf 'action'; }
check_git()       { have git       && git --version 2>/dev/null | awk '{print $3}'; }
check_screen()    { have screen    && screen --version 2>/dev/null | awk '{print $3}'; }
check_btop()      { have btop      && printf 'installed'; }
check_docker()    { have docker    && docker --version 2>/dev/null | awk '{print $3}' | tr -d ','; }
check_tailscale() { have tailscale && tailscale version 2>/dev/null | head -1; }
check_claude()    { as_user 'command -v claude >/dev/null 2>&1' && as_user 'timeout 10 claude --version' 2>/dev/null | awk '{print $1}'; }

pkg_index() {
    local want="$1" i
    for i in "${!PKG_KEYS[@]}"; do
        [ "${PKG_KEYS[i]}" = "$want" ] && { printf '%s' "$i"; return 0; }
    done
    return 1
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

# Claude Code lives in claude.sh. Prefer a copy sitting next to this script
# (running from a clone), otherwise fetch it.
install_claude() {
    say "Handing off to claude.sh"
    local here sibling
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || here=''
    sibling="$here/claude.sh"

    if [ -n "$here" ] && [ -r "$sibling" ]; then
        ok "using $sibling"
        bash "$sibling" install
    else
        have curl || { apt_refresh; apt_ensure curl curl; }
        ok "fetching $RAW_BASE/claude.sh"
        local tmp; tmp="$(mktemp)"
        if curl -fsSL "$RAW_BASE/claude.sh" -o "$tmp" && [ -s "$tmp" ]; then
            bash "$tmp" install
            local rc=$?
            rm -f "$tmp"
            return $rc
        fi
        rm -f "$tmp"
        warn "could not fetch claude.sh from $RAW_BASE"
        return 1
    fi
}

# ---------------------------------------------------------------- the picker --
# SELECTED[i] is 1 when entry i is chosen.
declare -a SELECTED

selection_reset() {
    local i
    for i in "${!PKG_KEYS[@]}"; do SELECTED[i]=0; done
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
    for i in "${!PKG_KEYS[@]}"; do
        key="${PKG_KEYS[i]}"
        raw="$("check_$key" 2>/dev/null)"
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
    selection_reset
    local input tok idx count=0

    while true; do
        print_catalog
        printf '  %s\n' "${C_DIM}numbers toggle · a=all · m=missing only · n=none · q=quit${C_RESET}"
        input="$(ask "Install [Enter to confirm]: " '')"

        case "$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')" in
            q|quit|exit) say "Nothing changed."; return 1 ;;
            a|all)  for idx in "${!PKG_KEYS[@]}"; do SELECTED[idx]=1; done; continue ;;
            n|none) selection_reset; continue ;;
            m|missing)
                selection_reset
                for idx in "${!PKG_KEYS[@]}"; do
                    [ "${PKG_KEYS[idx]}" = update ] && continue
                    [ -z "$("check_${PKG_KEYS[idx]}" 2>/dev/null)" ] && SELECTED[idx]=1
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
                    [ "${SELECTED[idx]}" = 1 ] && SELECTED[idx]=0 || SELECTED[idx]=1
                else
                    warn "no entry numbered $tok"
                fi
            elif idx="$(pkg_index "$tok")"; then
                [ "${SELECTED[idx]}" = 1 ] && SELECTED[idx]=0 || SELECTED[idx]=1
            else
                warn "unknown entry '$tok'"
            fi
        done
    done
}

run_selection() {
    local i key failed=() done_=()
    printf '\n%s\n' "${C_BOLD}Installing on $(hostname) for $TARGET_USER${C_RESET}"
    require_sudo
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
            all)     for idx in "${!PKG_KEYS[@]}"; do SELECTED[idx]=1; done ;;
            missing)
                for idx in "${!PKG_KEYS[@]}"; do
                    [ "${PKG_KEYS[idx]}" = update ] && continue
                    [ -z "$("check_${PKG_KEYS[idx]}" 2>/dev/null)" ] && SELECTED[idx]=1
                done ;;
            *)
                if idx="$(pkg_index "$name")"; then
                    SELECTED[idx]=1
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
	${C_BOLD}curl.sh${C_RESET} — pick the tools you want on an Ubuntu box and install them

	  bash <(curl -Ss https://raw.githubusercontent.com/mkolakowski/curl/main/curl.sh) [command]

	${C_BOLD}Commands${C_RESET}
	  (none)              interactive checklist
	  install <name>...   install the named entries without prompting
	  install all         install everything
	  install missing     install whatever is not there yet
	  list                show the catalog and what is already installed
	  update              apt update + full-upgrade only
	  reboot              reboot the machine
	  help                this text

	${C_BOLD}Entries${C_RESET}
	  ${PKG_KEYS[*]}

	${C_BOLD}Environment${C_RESET}
	  ASSUME_YES=1        never prompt, take the defaults
	  NO_COLOR=1          plain output

	Claude Code and its boot session live in claude.sh:
	  bash <(curl -Ss $RAW_BASE/claude.sh)

	  $REPO_URL
	USAGE
}

main() {
    case "${1:-}" in
        '')
            picker && run_selection ;;
        install|add|i)
            shift
            [ $# -gt 0 ] || die "nothing named. Try: curl.sh install all"
            select_by_name "$@"
            run_selection ;;
        list|ls)        list_catalog ;;
        update)         require_sudo; install_update ;;
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
