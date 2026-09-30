#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
#
# The record rule, checked from outside: before its first change every part
# of this project writes down what was there, and uninstall.sh and "off" put
# back exactly that - not what a new phone probably has.
#
#   snapshot -> install / on -> off / uninstall -> snapshot, identical
#
# for the cases a "put back the default" approach gets wrong: a file that was
# there before the install and is not ours, a unit somebody had enabled
# themselves, a user.js that existed empty, an about:config value that
# happens to equal ours. And the two cases where nothing may be restored: a
# file somebody changed after us (it stays, and uninstall says so), and an
# install from before records existed (the old behaviour, and it says so).
#
# A home of its own, the systemctl stub from lib.sh, no sudo. Nothing
# reaches the phone's units, its Firefox or beaconDB.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
. "$HERE/lib.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
REAL_PATH=$PATH
mkdir -p "$TMP/bin"
systemctl_stub "$TMP/bin/systemctl"
cat > "$TMP/bin/sudo" <<'STUB'
#!/bin/sh
echo "sudo is not available in the sandbox" >&2
exit 1
STUB
chmod +x "$TMP/bin/sudo"

if [ -e /usr/local/bin/gpsctl ] || grep -qF 127.0.0.1:8765 /etc/geoclue/geoclue.conf 2>/dev/null; then
    printf '  \033[33mskipped\033[0m - the retired filter is on this machine\n'
    exit 0
fi

snapshot() {
    (cd "$SANDBOX/home" || exit 1
     find . -type f -exec md5sum {} + | sort -k2
     find . -type l -printf 'link %p -> %l\n' | sort
     find . -mindepth 1 -type d -printf 'dir %p\n' | sort \
        | grep -vxE 'dir \./\.local(/bin|/share)?|dir \./\.config(/systemd(/user(/[^/]+\.wants)?)?)?')
}

# fresh <name>: a new sandbox with one Firefox profile.
fresh() {
    SANDBOX=$TMP/$1
    export SANDBOX
    export HOME=$SANDBOX/home XDG_RUNTIME_DIR=$SANDBOX/run
    unset XDG_CONFIG_HOME CONTRIB_STATE CONTRIB_UNIT FIREFOX_UNITS FURIOS_FIREFOX_ROOT
    unset DBUS_SESSION_BUS_ADDRESS
    export PATH=$TMP/bin:$REAL_PATH
    FF=$HOME/.mozilla/firefox
    mkdir -p "$FF/p.default" "$XDG_RUNTIME_DIR"
    printf '[Profile0]\nName=default\nIsRelative=1\nPath=p.default\n' > "$FF/profiles.ini"
}
inst()   { bash "$ROOT/install.sh" >/dev/null 2>&1 || echo "install.sh failed" >&2; }
uninst() { bash "$ROOT/uninstall.sh" 2>&1; }
contrib() { "$HOME/.local/bin/furios-gps-contribute" "$@" 2>&1; }
ffx()     { "$HOME/.local/bin/furios-gps-firefox" "$@" 2>&1; }
enabled() { systemctl --user is-enabled "$1" >/dev/null 2>&1 && echo yes || echo no; }
same()    { diff <(echo "$1") <(snapshot) | grep '^[<>]'; }

# --- the installer's own files ---------------------------------------------

fresh foreign-file
# Something that is not ours at one of our paths: install.sh replaces it, and
# uninstall.sh has to bring back THAT, not leave nothing.
mkdir -p "$HOME/.local/bin"
printf '#!/bin/sh\necho mine\n' > "$HOME/.local/bin/furios-gps-firefox"
chmod 700 "$HOME/.local/bin/furios-gps-firefox"
before=$(snapshot)
inst
check "foreign file: install.sh put ours there" "yes" \
    "$(grep -q furios-gps "$HOME/.local/bin/furios-gps-firefox" && echo yes)"
inst        # a second install must not write down our own file as the original
out=$(uninst)
check "foreign file: back, byte for byte and mode, after two installs" "" "$(same "$before")"
check "foreign file: uninstall says it put it back" "yes" \
    "$(grep -q 'put back .*furios-gps-firefox' <<<"$out" && echo yes)"

fresh changed-after-us
before=$(snapshot)
inst
echo "# my own addition" >> "$HOME/.config/systemd/user/furios-gps-contribute.service"
kept=$(md5sum < "$HOME/.config/systemd/user/furios-gps-contribute.service")
out=$(uninst)
check "changed after us: the edited unit stays as it is" "$kept" \
    "$(md5sum < "$HOME/.config/systemd/user/furios-gps-contribute.service" 2>/dev/null)"
check "changed after us: and uninstall says so" "yes" \
    "$(grep -q 'left .*furios-gps-contribute.service as it is' <<<"$out" && echo yes)"
check "changed after us: everything else is gone" "yes" \
    "$([ ! -e "$HOME/.local/bin/furios-gps-contribute" ] && [ ! -e "$HOME/.config/furios-gps" ] && echo yes)"

fresh no-record
before=$(snapshot)
inst
# An install from before 30.9.2026: the same files, no record.
rm -rf "$HOME/.config/furios-gps/install-record"
out=$(uninst)
check "no record: the old behaviour, everything removed" "" "$(same "$before")"
check "no record: and uninstall says it had none" "yes" \
    "$(grep -q 'No install record' <<<"$out" && echo yes)"

# --- furios-gps-contribute's unit ------------------------------------------

fresh unit-enabled-before
inst
# Somebody enabled the unit themselves before ever switching on: without the
# marker it exits at once, so that is harmless - and it is their state.
systemctl --user enable furios-gps-contribute.service
before=$(snapshot)
contrib on >/dev/null
contrib on >/dev/null      # twice: the record must still be the first one
contrib off >/dev/null
check "unit enabled before on: still enabled after off" "yes" \
    "$(enabled furios-gps-contribute.service)"
check "unit enabled before on: the home is as before on" "" "$(same "$before")"

fresh unit-disabled-before
inst
before=$(snapshot)
contrib on >/dev/null
check "unit disabled before on: on enables it" "yes" "$(enabled furios-gps-contribute.service)"
contrib off >/dev/null
check "unit disabled before on: off disables it, record gone" "" "$(same "$before")"

fresh unit-no-record
inst
contrib on >/dev/null
rm -f "$HOME/.config/furios-gps/unit-before-on"      # switched on before 30.9.
out=$(contrib off)
check "unit, no record: disabled as always" "no" "$(enabled furios-gps-contribute.service)"
check "unit, no record: and it says so" "yes" \
    "$(grep -q 'no record of the unit' <<<"$out" && echo yes)"

fresh unit-no-bus
inst
# No user manager: the state cannot be asked, so nothing is written down -
# a guess in the record would read as a fact later.
SANDBOX_NO_BUS=1 contrib on >/dev/null
check "no user manager: no record is invented" "no" \
    "$([ -e "$HOME/.config/furios-gps/unit-before-on" ] && echo yes || echo no)"

# --- furios-gps-firefox -----------------------------------------------------

fresh firefox-exact
inst
P=$FF/p.default
: > "$P/user.js"                                  # there, and empty
printf 'user_pref("a", 1);\nuser_pref("geo.provider.use_mls", false);\n' > "$P/prefs.js"
before=$(snapshot)
ffx on >/dev/null
check "firefox: on patched the profile" "3" "$(grep -c geo.provider "$P/user.js")"
check "firefox: on enabled the units" "yes" "$(enabled furios-gps-firefox.path)"
# Firefox copies the other two into prefs.js while it runs.
printf 'user_pref("geo.provider.geoclue.always_high_accuracy", true);\n' >> "$P/prefs.js"
ffx on >/dev/null
ffx off >/dev/null
check "firefox: empty user.js and an about:config value equal to ours - all as before" "" \
    "$(same "$before")"
check "firefox: that about:config value is still there" "1" \
    "$(grep -c use_mls "$P/prefs.js")"

fresh firefox-unit-enabled-before
inst
systemctl --user enable furios-gps-firefox.path   # somebody's own decision
before=$(snapshot)
ffx on >/dev/null; ffx off >/dev/null
check "firefox: the path unit somebody enabled stays enabled" "yes" \
    "$(enabled furios-gps-firefox.path)"
check "firefox: and the service it did not have stays disabled" "" "$(same "$before")"

fresh firefox-no-newline
inst
P=$FF/p.default
printf 'user_pref("mine", 1);' > "$P/user.js"      # no newline at the end
before=$(snapshot)
ffx on >/dev/null; ffx off >/dev/null
check "firefox: user.js without a final newline comes back byte for byte" "" "$(same "$before")"

fresh firefox-changed-after-us
inst
P=$FF/p.default
before=$(snapshot)
ffx on >/dev/null
# Somebody changes one of our values in about:config: not ours any more.
printf 'user_pref("geo.provider.geoclue.mls_fallback_timeout_ms", 5000);\n' > "$P/prefs.js"
ffx off >/dev/null
check "firefox: a value changed after us stays" "1" "$(grep -c 5000 "$P/prefs.js")"
check "firefox: user.js that on made is gone" "no" \
    "$([ -e "$P/user.js" ] && echo yes || echo no)"

fresh firefox-no-record
inst
P=$FF/p.default
ffx on >/dev/null
rm -f "$HOME/.config/furios-gps/firefox-record.json"   # switched on before 30.9.
out=$(ffx off)
check "firefox, no record: cleaned the old way" "no" \
    "$([ -e "$P/user.js" ] && echo yes || echo no)"
check "firefox, no record: and it says so" "yes" \
    "$(grep -q 'before records existed' <<<"$out" && grep -q 'no record of the units' <<<"$out" && echo yes)"

summary
