#!/usr/bin/env bash
#
# claude.sh — compatibility shim. The sessions live in curl.sh now.
#
# Everything this script used to do is "curl.sh session <command>" as of 4.1.0.
# This file stays at the same URL so that anything already pointing at it — a
# note, a shell history, a runbook — keeps working:
#
#   bash <(curl -Ss https://raw.githubusercontent.com/mkolakowski/curl/main/claude.sh) list
#
# is the same as
#
#   bash <(curl -Ss .../curl.sh) session list
#
# Prefer a copy of curl.sh sitting next to this one (running from a clone),
# otherwise fetch it.

set -uo pipefail

RAW_BASE="${CURL_SH_RAW_BASE:-https://raw.githubusercontent.com/mkolakowski/curl/main}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || here=''
sibling="$here/curl.sh"

if [ -n "$here" ] && [ -r "$sibling" ]; then
    exec bash "$sibling" session "$@"
fi

command -v curl >/dev/null 2>&1 || {
    printf '%s\n' "error curl is not installed, and this script is now a shim that needs it." >&2
    printf '%s\n' "      run curl.sh directly: $RAW_BASE/curl.sh" >&2
    exit 1
}

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
if curl -fsSL "$RAW_BASE/curl.sh" -o "$tmp" && [ -s "$tmp" ]; then
    bash "$tmp" session "$@"
    exit $?
fi

printf '%s\n' "error could not fetch curl.sh from $RAW_BASE" >&2
exit 1
