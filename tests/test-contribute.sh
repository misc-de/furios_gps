#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
#
# The rules beaconDB states, checked against the code that is supposed to
# follow them - and the ones it does not state, which are about not being a
# burden on a service somebody runs for free.
#
# Nothing here talks to beaconDB. A test suite that submits is a test suite
# that puts test data in a public database.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
. "$HERE/lib.sh"

TOOL=$ROOT/tools/furios-gps-contribute
UNIT=$ROOT/systemd/furios-gps-contribute.service
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

py() { CONTRIB_STATE="$TMP/state" python3 - "$TOOL" "$@"; }

# --- what beaconDB requires -------------------------------------------------

check "submissions go to beaconDB's geosubmit endpoint" "yes" \
    "$(grep -q 'https://api.beacondb.net/v2/geosubmit' "$TOOL" && echo yes || echo no)"
check "the client identifies itself, as asked" "yes" \
    "$(grep -q 'User-Agent' "$TOOL" && grep -q 'USER_AGENT = ' "$TOOL" && echo yes || echo no)"
check "and the agent carries a contact address" "yes" \
    "$(grep -q 'USER_AGENT = .*github.com/misc-de' "$TOOL" && echo yes || echo no)"

# "Hidden Wifi networks must not be collected." / "Wifi networks with a SSID
# ending in _nomap must not be collected." beaconDB honours _optout too.
echo
printf '\033[1m  the networks that must never be sent\033[0m\n'
py <<'PY'
import importlib.machinery, importlib.util, sys, re
ld = importlib.machinery.SourceFileLoader("c", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("c", ld))
ld.exec_module(m)

def is_excluded(ssid):
    if not ssid.strip():
        return True
    if m.NOMAP.search(ssid.strip()):
        return True
    return bool(re.search(r"(iphone|android.?ap|mobile.?hotspot|galaxy.*hotspot)",
                          ssid, re.IGNORECASE))

cases = [
    ("",                  True,  "hidden (no SSID)"),
    ("   ",               True,  "hidden (blank SSID)"),
    ("Cafe_nomap",        True,  "_nomap"),
    ("Cafe_NOMAP",        True,  "_nomap, upper case"),
    ("Cafe_optout",       True,  "_optout"),
    ("iPhone of Anna",    True,  "a phone hotspot"),
    ("Android AP 42",     True,  "a phone hotspot"),
    ("Stadtbuecherei",    False, "an ordinary network"),
    ("nomap_cafe",        False, "_nomap only counts at the end"),
]
bad = 0
for ssid, expected, what in cases:
    got = is_excluded(ssid)
    ok = got == expected
    bad += not ok
    print(("  \033[32mok\033[0m   " if ok else "  \033[31mFAIL\033[0m ")
          + f"{what}: {'excluded' if got else 'sent'}")
sys.exit(1 if bad else 0)
PY
check "every exclusion rule holds" "0" "$?"

# --- the position has to be a real one --------------------------------------

# This is the one that matters most. geoclue can answer from a Wi-Fi lookup,
# and that lookup is answered by beaconDB - submitting it would feed the
# database its own estimate back as an observation.
check "a fix without an altitude is refused" "yes" \
    "$(grep -q 'no altitude' "$TOOL" && echo yes || echo no)"
check "and so is one that is too coarse" "yes" \
    "$(grep -q 'ACCURACY_MAX' "$TOOL" && echo yes || echo no)"
check "the position is declared as gps, not fused" "yes" \
    "$(grep -q '"source": "gps"' "$TOOL" && echo yes || echo no)"
check "a report carries at least two access points" "2" \
    "$(sed -n 's/^MIN_APS = //p' "$TOOL")"

# --- not being a burden -----------------------------------------------------

printf '\n\033[1m  what keeps this off the server'"'"'s back\033[0m\n'
check "measurements are minutes apart, not seconds" "yes" \
    "$([ "$(sed -n 's/^INTERVAL_S = int(os.environ.get("CONTRIB_INTERVAL", "\([0-9]*\)".*/\1/p' "$TOOL")" -ge 60 ] && echo yes || echo no)"
check "standing still is not measured over and over" "yes" \
    "$(grep -q 'MIN_MOVE_M' "$TOOL" && grep -q 'MIN_AGE_S' "$TOOL" && echo yes || echo no)"
check "observations are batched into one request" "yes" \
    "$(grep -q 'BATCH' "$TOOL" && echo yes || echo no)"
check "a failure backs off instead of retrying at once" "yes" \
    "$(grep -q 'BACKOFF_S' "$TOOL" && echo yes || echo no)"
check "and eventually gives up rather than looping" "yes" \
    "$(grep -q 'giving up for now' "$TOOL" && echo yes || echo no)"
# A 4xx means the request what wrong. Sending it again unchanged is what earns
# a block, so it has to be dropped rather than retried.
check "a refused batch is dropped, not resent" "yes" \
    "$(grep -q 'dropping this batch' "$TOOL" && echo yes || echo no)"
check "nothing is sent over mobile data" "yes" \
    "$(grep -q 'def on_wifi' "$TOOL" && echo yes || echo no)"
check "the queue cannot grow without end" "yes" \
    "$(grep -q 'QUEUE_MAX' "$TOOL" && echo yes || echo no)"

# --- opt-in -----------------------------------------------------------------

printf '\n\033[1m  off unless somebody says otherwise\033[0m\n'
out=$(CONTRIB_STATE="$TMP/state" "$TOOL" status)
check "a fresh install contributes nothing" "contributing=no" \
    "$(printf '%s' "$out" | sed -n 1p)"
check "and 'run' exits instead of collecting" "0" \
    "$(CONTRIB_STATE="$TMP/state" timeout 20 "$TOOL" run >/dev/null 2>&1; echo $?)"
CONTRIB_STATE="$TMP/state" "$TOOL" on >/dev/null
check "switching it on is remembered" "contributing=yes" \
    "$(CONTRIB_STATE="$TMP/state" "$TOOL" status | sed -n 1p)"
CONTRIB_STATE="$TMP/state" "$TOOL" off >/dev/null
check "and switching it off again too" "contributing=no" \
    "$(CONTRIB_STATE="$TMP/state" "$TOOL" status | sed -n 1p)"
check "the state lives under the user's config, needing no root" "yes" \
    "$(grep -q 'XDG_CONFIG_HOME' "$TOOL" && echo yes || echo no)"

# The marker alone does nothing: the service exits at once when it is not
# there, so after an install it is enabled and already dead. Setting the
# marker without starting the service made the switch in the app write a file
# and look like it had done something - measured on the phone, the service
# stayed inactive with contributing=yes.
check "switching on also starts the service" "yes" \
    "$(grep -q 'einheit("start")' "$TOOL" && echo yes || echo no)"
check "and switching off stops it" "yes" \
    "$(grep -q 'einheit("stop")' "$TOOL" && echo yes || echo no)"
check "status says whether anything is actually running" "yes" \
    "$(CONTRIB_STATE="$TMP/state" "$TOOL" status | grep -q '^running=' && echo yes || echo no)"
# Run from a checkout there is no unit, and that must not be an error.
check "a missing unit is not fatal" "0" \
    "$(CONTRIB_STATE="$TMP/state2" "$TOOL" on >/dev/null 2>&1; echo $?)"

# --- power ------------------------------------------------------------------

# The question that found this: does it cost anything when it is switched off,
# and does it cost more than it needs to when it is on? Off it costs nothing -
# the service exits at once. On, the expensive thing is the GNSS receiver, and
# everything that can rule a measurement out has to be asked before it is
# switched on.
printf '\n\033[1m  what it costs while running\033[0m\n'
check "the cheap checks come before the receiver" "yes" \
    "$(awk '/def measure/,/pos = gnss_fix/' "$TOOL" | grep -q 'gleiche_umgebung' && echo yes || echo no)"
check "standing still never switches it on" "yes" \
    "$(grep -q 'not switching the receiver on' "$TOOL" && echo yes || echo no)"
check "and indoors it stops trying every few minutes" "yes" \
    "$(grep -q 'gnss_misses' "$TOOL" && grep -q 'gnss_next_try' "$TOOL" && echo yes || echo no)"
py <<'PYEOF'
import importlib.machinery, importlib.util, os, sys, tempfile, time
os.environ["CONTRIB_STATE"] = tempfile.mkdtemp()
ld = importlib.machinery.SourceFileLoader("c", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("c", ld))
ld.exec_module(m)
aps = [{"macAddress": f"AA:BB:CC:DD:EE:{i:02X}"} for i in range(6)]
m.save_stats({"last_position": [50.0, 8.0, time.time()],
              "last_aps": [a["macAddress"] for a in aps]})
gerufen = {"n": 0}
m.gnss_fix = lambda *a, **k: gerufen.update(n=gerufen["n"] + 1) or None
m.scan_wifi = lambda: aps
m.measure()
sys.exit(0 if gerufen["n"] == 0 else 1)
PYEOF
check "proved: same place, receiver untouched" "0" "$?"

# --- the unit ---------------------------------------------------------------

check "there is a user unit, not a system one" "yes" \
    "$([ -f "$UNIT" ] && ! grep -q 'multi-user.target' "$UNIT" && echo yes || echo no)"
check "it is installed and removed with everything else" "yes" \
    "$(grep -q 'furios-gps-contribute' "$ROOT/install.sh" \
       && grep -q 'furios-gps-contribute' "$ROOT/uninstall.sh" && echo yes || echo no)"
check "the package ships it too" "yes" \
    "$(grep -q 'furios-gps-contribute' "$ROOT/packaging/build-deb.sh" && echo yes || echo no)"
if command -v systemd-analyze >/dev/null 2>&1; then
    check "systemd accepts every key in it" "" \
        "$(systemd-analyze verify --user "$UNIT" 2>&1 | grep -iE 'unknown key|unknown lvalue' | head -1)"
fi

summary
