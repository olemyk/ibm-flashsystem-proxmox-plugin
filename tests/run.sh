#!/bin/sh
# Syntax-check and unit-test the FlashSystem plugin.
#
# Runs anywhere perl exists. ./stub holds PVE's own modules AND the plugin's
# non-core CPAN dependencies — JSON, LWP::UserAgent, HTTP::Request. The last
# three are installed on every node by flashsystem_plugin_packages but are NOT
# on a bare CI runner, and `use` runs at BEGIN, so their absence killed the
# very first command below before a single case ran. If you add a non-core
# `use` to the plugin, add a stub for it in ./stub at the same time, or the
# pipeline finds out for you.
#
# Because ./stub is FIRST on @INC, these shims win even on a machine that has
# the real modules — deliberately, so the suite behaves the same everywhere.
# Dual-home: works from a vendored layout (module in ../files/)
# and from the standalone repo (module in ../).
set -eu
cd "$(dirname "$0")"
MOD=../files/FlashSystemPlugin.pm
[ -f "$MOD" ] || MOD=../FlashSystemPlugin.pm
GUI=../files/flashsystem-gui.js
[ -f "$GUI" ] || GUI=../gui/flashsystem-gui.js
# -T on every one of these, because PVE runs pvedaemon/pveproxy/pvestatd
# under taint mode and this suite did not. A tainted path is legal in a read
# open() and illegal in a write one, so the plugin's SCSI rescans and path
# deletes had been failing on every node since the first release while the
# whole suite stayed green. Never run these without -T.
perl -T -I stub -c "$MOD"
perl -T t_prefix.pl
perl -T t_status.pl
perl -T t_names.pl
perl -T t_resize.pl
perl -T t_api.pl

# The GUI render helpers, executed against fixtures with a stubbed ExtJS.
# Two of the six defects found in review were renderer-only - data the API
# computed and returned that nothing ever displayed - which no Perl test can
# see. Skipped rather than failed where node is unavailable: this must not
# block a plain Ansible run on a host without it.
if command -v node >/dev/null 2>&1; then
    node --check "$GUI" && node t_gui.js
else
    echo "t_gui.js  SKIPPED (node not installed)"
fi

# ── Vendored-file checksums ─────────────────────────────────────────────────
# defaults/main.yml pins a sha256 per vendored file, and the Ansible preflight
# refuses to install when one drifts. That check runs on the RUNNER, so a pin
# left stale by an intentional edit is only discovered a full pipeline
# round-trip later — which is exactly what happened on 2026-08-31, after a
# change whose 319 local assertions all passed. Check it here, next to the
# edit. Skipped in the standalone repo, which has no Ansible defaults.
MANIFEST=../defaults/main.yml
FILES=../files
[ -d "$FILES" ] || FILES=..
if [ -f "$MANIFEST" ]; then
    if command -v sha256sum >/dev/null 2>&1; then SHA='sha256sum'; else SHA='shasum -a 256'; fi
    drift=0
    for f in FlashSystemPlugin.pm flashsystem-gui.js install-flashsystem-gui.sh \
             FlashSystemAPI.pm install-flashsystem-api.sh; do
        [ -f "$FILES/$f" ] || continue
        # Exact key match: the filenames contain dots, so a regex would be
        # matching them as wildcards.
        want=$(awk -v k="$f:" '$1 == k { gsub(/"/, "", $2); print $2 }' "$MANIFEST")
        got=$($SHA "$FILES/$f" | cut -d' ' -f1)
        if [ -z "$want" ]; then
            echo "checksum   $f  NOT PINNED in defaults/main.yml"
            drift=1
        elif [ "$want" != "$got" ]; then
            echo "checksum   $f  DRIFTED"
            echo "             pinned $want"
            echo "             actual $got"
            drift=1
        fi
    done
    if [ "$drift" -ne 0 ]; then
        echo
        echo "Update flashsystem_plugin_file_checksums in $MANIFEST before pushing."
        echo "The pipeline preflight rejects these files otherwise, and that"
        echo "costs a whole runner job to find out."
        exit 1
    fi
    echo "checksums  5 vendored files match defaults/main.yml"
fi
