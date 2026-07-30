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
readonly VERSION="2.12.0"          # keep in step with the top entry of CHANGELOG.md
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

# Printed once per run so it is obvious which version is on the box — these are
# curled straight off main, so "which one am I running" is a fair question.
banner() { printf '%s\n' "${C_DIM}curl.sh $VERSION${C_RESET}"; }

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
    "Claude Code + boot session (runs claude.sh)"
)

# check_<key> prints a short state string; empty output means "not installed".
check_update()    { printf 'action'; }
check_git()       { have git       && git --version 2>/dev/null | awk '{print $3}'; }
check_gh()        { have gh        && gh --version 2>/dev/null | head -1 | awk '{print $3}'; }
check_screen()    { have screen    && screen --version 2>/dev/null | awk '{print $3}'; }
check_btop()      { have btop      && printf 'installed'; }
check_docker()    { have docker    && docker --version 2>/dev/null | awk '{print $3}' | tr -d ','; }
check_tailscale() { have tailscale && tailscale version 2>/dev/null | head -1; }
# Read the version from package.json rather than running the binary: purplemux
# is a server, and an unrecognised --version could start it instead of printing.
check_purplemux() {
    have purplemux || return 1
    local pj root
    # Ask npm where global packages live rather than assuming a prefix; a user
    # with an npm prefix in their profile puts them somewhere else entirely.
    root="$(npm root -g 2>/dev/null)"
    for pj in "${root:-/nonexistent}/purplemux/package.json" \
              /usr/lib/node_modules/purplemux/package.json \
              /usr/local/lib/node_modules/purplemux/package.json; do
        if [ -r "$pj" ]; then
            sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$pj" | head -1
            return 0
        fi
    done
    printf 'installed'
}
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
    skip "start it with: purplemux   (then open http://localhost:8022)"
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

dc_state() {
    have docker || { printf '%s' '-'; return; }
    local names
    names="$($SUDO docker ps --format '{{.Names}}' 2>/dev/null)"
    if printf '%s\n' "$names" | grep -qx "$1"; then printf '%s' 'running'; return; fi
    names="$($SUDO docker ps -a --format '{{.Names}}' 2>/dev/null)"
    if printf '%s\n' "$names" | grep -qx "$1"; then printf '%s' 'stopped'; return; fi
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
    $SUDO install -m 0600 "$tmp" "$dir/.env"
    rm -f "$tmp"
    $SUDO chown "$TARGET_USER" "$dir/.env" 2>/dev/null
    return $missing
}

dc_compose_cmd() {
    if $SUDO docker compose version >/dev/null 2>&1; then printf '%s' 'docker compose'
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
    $SUDO mkdir -p "$dir"
    $SUDO chown "$TARGET_USER" "$dir" 2>/dev/null

    local tmp; tmp="$(mktemp)"
    dc_compose_for "$name" > "$tmp"
    if [ -r "$dir/docker-compose.yml" ] && ! cmp -s "$tmp" "$dir/docker-compose.yml"; then
        $SUDO cp -p "$dir/docker-compose.yml" "$dir/docker-compose.yml.bak"
        warn "kept your previous compose file as docker-compose.yml.bak"
    fi
    $SUDO install -m 0644 "$tmp" "$dir/docker-compose.yml"
    rm -f "$tmp"
    $SUDO chown "$TARGET_USER" "$dir/docker-compose.yml" 2>/dev/null
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
    # shellcheck disable=SC2086  # $cc is "docker compose", two words on purpose
    if out="$( cd "$dir" && $SUDO $cc up -d 2>&1 )"; then
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
    # shellcheck disable=SC2086  # $cc and $args are deliberately word-split
    if out="$( cd "$dir" && $SUDO $cc $args 2>&1 )"; then
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
    printf '\n  %-3s %-3s %-14s %-9s %s\n' '' '#' 'container' 'state' 'what it is'
    printf '  %s\n' "$(printf '%.0s-' {1..72})"
    for i in "${!DC_KEYS[@]}"; do
        key="${DC_KEYS[i]}"
        st="$(dc_state "$key")"
        printf -v pad '%-9s' "$st"
        case "$st" in
            running) pad="${C_GREEN}${pad}${C_RESET}" ;;
            stopped|written) pad="${C_YELLOW}${pad}${C_RESET}" ;;
            *) pad="${C_DIM}${pad}${C_RESET}" ;;
        esac
        [ "${DC_SELECTED[i]:-0}" = 1 ] && mark="${C_GREEN}[x]${C_RESET}" || mark='[ ]'
        printf '  %b %-3s %-14s %b %s\n' "$mark" "$((i + 1))" "$key" "$pad" "${C_DIM}${DC_BLURB[i]}${C_RESET}"
    done
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
    local input tok idx count
    while true; do
        printf '%s' "${C_BOLD}Docker containers${C_RESET}"
        dc_print_catalog
        printf '  %s\n' "${C_DIM}stacks live in $STACKS_DIR · numbers toggle · a=all · n=none${C_RESET}"
        printf '  %s\n' "${C_DIM}Enter=install · s=start · x=stop · r=restart · q=back${C_RESET}"
        input="$(ask "Choice [Enter to install]: " '')"
        case "$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')" in
            q|quit|back) return 0 ;;
            a|all)  for idx in "${!DC_KEYS[@]}"; do DC_SELECTED[idx]=1; done; continue ;;
            n|none) dc_reset; continue ;;
            '')        require_sudo; dc_apply install && dc_reset; continue ;;
            s|start)   require_sudo; dc_apply start   && dc_reset; continue ;;
            x|stop)    require_sudo; dc_apply stop    && dc_reset; continue ;;
            r|restart) require_sudo; dc_apply restart && dc_reset; continue ;;
        esac
        for tok in $(printf '%s' "$input" | tr ',' ' '); do
            if printf '%s' "$tok" | grep -qE '^[0-9]+$'; then
                idx=$((tok - 1))
                if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#DC_KEYS[@]}" ]; then
                    [ "${DC_SELECTED[idx]}" = 1 ] && DC_SELECTED[idx]=0 || DC_SELECTED[idx]=1
                else warn "no entry numbered $tok"; fi
            elif idx="$(dc_index "$tok")"; then
                [ "${DC_SELECTED[idx]}" = 1 ] && DC_SELECTED[idx]=0 || DC_SELECTED[idx]=1
            else warn "unknown container '$tok'"; fi
        done
    done
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
        printf '  %s\n' "${C_DIM}numbers toggle · a=all · m=missing only · n=none · d=docker containers · q=quit${C_RESET}"
        input="$(ask "Install [Enter to confirm]: " '')"

        case "$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')" in
            q|quit|exit) say "Nothing changed."; return 1 ;;
            d|docker|containers) docker_menu; continue ;;
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
	${C_BOLD}curl.sh${C_RESET} $VERSION — pick the tools you want on an Ubuntu box and install them

	  bash <(curl -Ss https://raw.githubusercontent.com/mkolakowski/curl/main/curl.sh) [command]

	${C_BOLD}Commands${C_RESET}
	  (none)              interactive checklist
	  install <name>...   install the named entries without prompting
	  install all         install everything
	  install missing     install whatever is not there yet
	  list                show the catalog and what is already installed
	  containers [start|stop|restart] [name...]
	                      docker container stacks: cloudflared, beszel-agent,
	                      dockge. No arguments opens the checklist; a bare verb
	                      acts on every installed stack.
	  update              apt update + full-upgrade only
	  reboot              reboot the machine
	  version             print the version and exit
	  help                this text

	${C_BOLD}Entries${C_RESET}
	  ${PKG_KEYS[*]}

	${C_BOLD}Environment${C_RESET}
	  CURL_SH_STACKS_DIR  where compose stacks are written (now: $STACKS_DIR)
	  ASSUME_YES=1        never prompt, take the defaults
	  NO_COLOR=1          plain output

	Claude Code and its boot session live in claude.sh:
	  bash <(curl -Ss $RAW_BASE/claude.sh)

	  $REPO_URL
	USAGE
}

main() {
    case "${1:-}" in
        version|--version|-V) printf '%s\n' "$VERSION"; return 0 ;;
    esac
    banner
    case "${1:-}" in
        '')
            picker && run_selection ;;
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
                require_sudo
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
                require_sudo
                local k rc=0 acted=0
                for k in "${DC_KEYS[@]}"; do
                    [ -r "$(dc_dir "$k")/docker-compose.yml" ] || continue
                    acted=1; dc_control "$verb" "$k" || rc=1
                done
                [ "$acted" = 1 ] || warn "no container stacks installed yet"
                return $rc
            fi
            docker_menu ;;
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
