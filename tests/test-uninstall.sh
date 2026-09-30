#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
#
# The invariant: after install.sh, the tools switched on, and uninstall.sh,
# the home is byte for byte the home before install.sh. Anything install.sh
# or the tools write that uninstall.sh does not take away shows up here as a
# path - without this test knowing which paths those are.
#
# Everything runs in a home of its own. systemctl and sudo are stubs first on
# the PATH: the stub systemctl makes and removes the enable links the way the
# real one does, and fails like the real one when a unit file is missing or
# when there is no user manager to talk to. Nothing reaches the phone's own
# units, its Firefox or beaconDB.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
. "$HERE/lib.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
REAL_PATH=$PATH

make_stubs() {
    mkdir -p "$TMP/bin"
    cat > "$TMP/bin/systemctl" <<'STUB'
#!/bin/bash
echo "$*" >> "$SANDBOX/systemctl.log"
if [ "${SANDBOX_NO_BUS:-}" = 1 ]; then
    echo "Failed to connect to bus: No medium found" >&2; exit 1
fi
user=; verb=; units=()
for a; do
    case $a in
        --user) user=1 ;;
        -*) ;;
        *) if [ -z "$verb" ]; then verb=$a; else units+=("$a"); fi ;;
    esac
done
[ -n "$user" ] || { echo "no system manager in the sandbox" >&2; exit 1; }
dir=$HOME/.config/systemd/user
case $verb in
    enable|disable)
        for u in "${units[@]}"; do
            [ -f "$dir/$u" ] || { echo "Unit file $u does not exist." >&2; exit 1; }
            if [ "$verb" = enable ]; then
                for t in $(sed -n 's/^WantedBy=//p' "$dir/$u"); do
                    mkdir -p "$dir/$t.wants"
                    ln -sf "$dir/$u" "$dir/$t.wants/$u"
                done
            else
                rm -f "$dir"/*.wants/"$u"
            fi
        done ;;
    is-enabled) for u in "${units[@]}"; do ls "$dir"/*.wants/"$u" >/dev/null 2>&1 || exit 1; done ;;
    is-active) exit 3 ;;
esac
exit 0
STUB
    cat > "$TMP/bin/sudo" <<'STUB'
#!/bin/sh
echo "$*" >> "$SANDBOX/sudo.log"
echo "sudo is not available in the sandbox" >&2
exit 1
STUB
    chmod +x "$TMP/bin/systemctl" "$TMP/bin/sudo"
}

# Files and links with their content, and every directory - the generic
# parents install -D makes along the way excepted, which a new phone may or
# may not have and which change nothing.
snapshot() {
    (cd "$SANDBOX/home" || exit 1
     find . -type f -exec md5sum {} + | sort -k2
     find . -type l -printf 'link %p -> %l\n' | sort
     find . -mindepth 1 -type d -printf 'dir %p\n' | sort \
        | grep -vxE 'dir \./\.local(/bin|/share)?|dir \./\.config(/systemd(/user(/[^/]+\.wants)?)?)?')
}

scenario() {
    # scenario <name> <extra env for uninstall.sh>
    local name=$1 nobus=$2
    SANDBOX=$TMP/$name
    export SANDBOX
    mkdir -p "$SANDBOX/home/.mozilla/firefox/p.default" "$SANDBOX/run"
    cat > "$SANDBOX/home/.mozilla/firefox/profiles.ini" <<'INI'
[Profile0]
Name=default
IsRelative=1
Path=p.default
INI
    printf 'user_pref("somebody.else", 1);\n' > "$SANDBOX/home/.mozilla/firefox/p.default/prefs.js"
    local before after
    before=$(HOME=$SANDBOX/home snapshot)

    (
        export HOME=$SANDBOX/home XDG_RUNTIME_DIR=$SANDBOX/run
        unset XDG_CONFIG_HOME CONTRIB_STATE CONTRIB_UNIT FIREFOX_UNITS FURIOS_FIREFOX_ROOT
        unset DBUS_SESSION_BUS_ADDRESS
        export PATH=$TMP/bin:$REAL_PATH
        bash "$ROOT/install.sh" >/dev/null 2>&1 || echo "install.sh failed" >&2
        # Everything a user can switch on, and what the tools leave while
        # they run: the queue, the counters, their temporary siblings.
        "$HOME/.local/bin/furios-gps-contribute" on >/dev/null 2>&1
        "$HOME/.local/bin/furios-gps-firefox" on >/dev/null 2>&1
        st=$HOME/.config/furios-gps
        echo '{}' > "$st/queue.jsonl"; echo '{}' > "$st/queue.jsonl.tmp"
        echo '{}' > "$st/contribute-stats.json"; echo '{}' > "$st/contribute-stats.json.tmp"
        mkdir -p "$HOME/.local/bin/__pycache__"
        : > "$HOME/.local/bin/__pycache__/furios-gps-contributecpython-313.pyc"
        : > "$HOME/.mozilla/firefox/p.default/user.js.furios-gps.tmp"
        SANDBOX_NO_BUS=$nobus bash "$ROOT/uninstall.sh" >/dev/null 2>&1 \
            || echo "uninstall.sh failed" >&2
    )
    after=$(HOME=$SANDBOX/home snapshot)
    check "$name: the home is the one before install.sh" "" \
        "$(diff <(echo "$before") <(echo "$after") | grep '^[<>]')"
    check "$name: install and uninstall never asked for root" "" \
        "$(cat "$SANDBOX/sudo.log" 2>/dev/null)"
}

make_stubs
# The phone this runs on must not carry the retired filter: uninstall.sh
# would then (rightly) ask for root, which the sandbox cannot give.
if [ -e /usr/local/bin/gpsctl ] || grep -qF 127.0.0.1:8765 /etc/geoclue/geoclue.conf 2>/dev/null; then
    printf '  \033[33mskipped\033[0m - the retired filter is on this machine\n'
    exit 0
fi
scenario "with a user manager" ""
scenario "without a user manager (ssh)" 1

summary
