#!/bin/zsh
# Runs when explicitly requested or when the developer option is enabled.
set -eu
if [[ "${1:-}" != --manual && "${CELL_PLUGIN_OPTION_checkAtLaunch:-false}" != true ]]; then
    exit 0
fi
report="$(mktemp "${CELL_PREFIX}/.sky-dns-XXXXXX")"
trap 'rm -f "$report"' EXIT
for host in store.steampowered.com thatgamecompany.helpshift.com; do
    if /usr/bin/dscacheutil -q host -a name "$host" | /usr/bin/grep -q 'address:'; then
        printf '%s resolved\n' "$host" >> "$report"
    else
        printf '%s could not be resolved\n' "$host" >> "$report"
    fi
done
/usr/bin/mv -f "$report" "${CELL_PREFIX}/cell-sky-dns.log"
/bin/cat "${CELL_PREFIX}/cell-sky-dns.log"
