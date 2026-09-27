#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
#
# furios-gps-firefox against a Firefox directory of its own: what goes into
# user.js, what comes out again, and what it must leave alone - the web app
# manager's block, and anything somebody set by hand.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
. "$HERE/lib.sh"

TOOL=$ROOT/tools/furios-gps-firefox
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

FF=$TMP/firefox
export FURIOS_FIREFOX_ROOT=$FF
export CONTRIB_STATE=$TMP/state
export FIREFOX_UNITS="furios-gps-firefox-test-does-not-exist.path"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/systemctl" <<STUB
#!/bin/sh
echo "\$*" >> "$TMP/systemctl.log"
exit 3
STUB
chmod +x "$TMP/bin/systemctl"
export PATH="$TMP/bin:$PATH"

mkdir -p "$FF/a.default" "$FF/webapp_x" "$FF/gone-dir-parent" "$TMP/abs"
cat > "$FF/profiles.ini" <<INI
[General]
StartWithLastProfile=1

[Profile0]
Name=default
IsRelative=1
Path=a.default

[Profile1]
Name=webapp_x
IsRelative=1
Path=webapp_x

[Profile2]
Name=missing
IsRelative=1
Path=does-not-exist

[Profile3]
Name=absolute
IsRelative=0
Path=$TMP/abs

[Install4F96D1932A9F858E]
Default=a.default
INI

MANAGED='// WEBAPP MANAGED START
user_pref("browser.startup.page", 0);
// WEBAPP MANAGED END'
printf '%s\n' "$MANAGED" > "$FF/webapp_x/user.js"
# The block written by hand on 27.9.2026, before the tool existed.
cat > "$FF/a.default/user.js" <<'JS'
user_pref("mine.own", 1);
// GPS: wait for geoclue's GNSS fix instead of giving up after 12 s
user_pref("geo.provider.use_mls", false);
user_pref("geo.provider.geoclue.mls_fallback_timeout_ms", 180000);
user_pref("geo.provider.geoclue.always_high_accuracy", true);
JS

st() { "$TOOL" status | sed -n "s/^$1=//p"; }
n_prefs() { grep -c 'geo.provider' "$1" 2>/dev/null || true; }

check "off after installation" "no" "$(st firefox_wait)"
check "finds the three existing profiles, skips the missing one" "3" "$(st profiles)"
check "status changes nothing" "$MANAGED" "$(cat "$FF/webapp_x/user.js")"

"$TOOL" on >/dev/null
check "on: every profile patched" "3" "$(st patched)"
check "on: the prefs once, not twice (hand-written block taken over)" "3" \
    "$(n_prefs "$FF/a.default/user.js")"
check "on: own pref kept" "1" "$(grep -c 'mine.own' "$FF/a.default/user.js")"
check "on: web app manager block kept" "1" \
    "$(grep -c 'WEBAPP MANAGED START' "$FF/webapp_x/user.js")"
check "on: profile without user.js gets one" "3" "$(n_prefs "$TMP/abs/user.js")"
check "on: enables the units" "yes" \
    "$(grep -q '^--user enable' "$TMP/systemctl.log" && echo yes)"
cp "$FF/webapp_x/user.js" "$TMP/before"
"$TOOL" apply >/dev/null
check "apply twice changes nothing" "" "$(diff "$TMP/before" "$FF/webapp_x/user.js")"

# The web app manager rewrites its block the way it does it: strip, append.
python3 - "$FF/webapp_x/user.js" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r"// WEBAPP MANAGED START\n.*?// WEBAPP MANAGED END\n", "", s, flags=re.S)
s = s.rstrip() + "\n" + '// WEBAPP MANAGED START\nuser_pref("x", 2);\n// WEBAPP MANAGED END\n'
open(p, "w").write(s)
PY
check "survives the web app manager rewriting its block" "3" \
    "$(n_prefs "$FF/webapp_x/user.js")"

# Firefox copied the values into prefs.js while it ran; one profile is open.
for p in a.default webapp_x; do
    printf 'user_pref("geo.provider.use_mls", false);\nuser_pref("other", 1);\n' \
        > "$FF/$p/prefs.js"
done
printf 'user_pref("geo.provider.geoclue.mls_fallback_timeout_ms", 30000);\n' \
    >> "$FF/a.default/prefs.js"
sleep 300 & OPEN=$!
ln -s "127.0.0.1:+$OPEN" "$FF/webapp_x/lock"

: > "$TMP/systemctl.log"
"$TOOL" off >/dev/null
check "off: marker gone" "no" "$(st firefox_wait)"
check "off: no user.js carries the block" "0" "$(st patched)"
check "off: own pref kept" "1" "$(grep -c 'mine.own' "$FF/a.default/user.js")"
check "off: web app manager block kept" "1" \
    "$(grep -c 'WEBAPP MANAGED START' "$FF/webapp_x/user.js")"
check "off: our value removed from a closed profile's prefs.js" "0" \
    "$(grep -c 'use_mls' "$FF/a.default/prefs.js")"
check "off: a value set by hand (30000) is not ours and stays" "1" \
    "$(grep -c '30000' "$FF/a.default/prefs.js")"
check "off: the rest of prefs.js stays" "1" "$(grep -c '"other"' "$FF/a.default/prefs.js")"
check "off: an open profile's prefs.js is not touched" "1" \
    "$(grep -c 'use_mls' "$FF/webapp_x/prefs.js")"
check "off: status counts it as left over" "1" "$(st leftover)"
check "off: units stay while something is left" "" "$(cat "$TMP/systemctl.log")"

kill "$OPEN" 2>/dev/null; wait "$OPEN" 2>/dev/null
"$TOOL" apply >/dev/null
check "next login: closed now, cleaned" "0" "$(grep -c 'use_mls' "$FF/webapp_x/prefs.js")"
check "next login: nothing left" "0" "$(st leftover)"
check "next login: units step aside" "yes" \
    "$(grep -q '^--user disable' "$TMP/systemctl.log" && echo yes)"

# A stale lock from a crash is not an open profile.
printf 'user_pref("geo.provider.use_mls", false);\n' > "$FF/webapp_x/prefs.js"
"$TOOL" off >/dev/null
check "stale lock (dead pid) does not block the cleanup" "0" \
    "$(grep -c 'use_mls' "$FF/webapp_x/prefs.js")"

rm "$FF/profiles.ini"
check_status "no Firefox at all is not an error" 0 "$TOOL" status

summary
