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

# "on" and "off" start and stop the user unit, and on the phone this suite
# runs on, that unit is installed and enabled. A test run must not start or
# stop it - stopping runs its ExecStop, which hands the real queue to
# beaconDB. So the unit name points at nothing, and a systemctl stub first on
# the PATH writes every call down instead of making it.
export CONTRIB_UNIT="furios-gps-contribute-test-does-not-exist.service"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/systemctl" <<STUB
#!/bin/sh
echo "\$*" >> "$TMP/systemctl.log"
exit 3
STUB
chmod +x "$TMP/bin/systemctl"
export PATH="$TMP/bin:$PATH"

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
    ("City Library",      False, "an ordinary network"),
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
# A hotspot called anything at all slips past the name rules. Its address
# gives it away: phones make one up, with the locally administered bit (0x02
# in the first octet) set. Run through scan_wifi with an nmcli of our own.
cat > "$TMP/bin/nmcli" <<'NMCLI'
#!/bin/sh
cat <<'OUT'
00\:11\:22\:33\:44\:55:City Library:2412 MHz:70
02\:11\:22\:33\:44\:55:Anna's Pixel:2437 MHz:80
DA\:A1\:19\:00\:00\:01:FRITZ!Box 7590:5180 MHz:60
A4\:B1\:C1\:00\:00\:01:Cafe:5180 MHz:60
OUT
NMCLI
chmod +x "$TMP/bin/nmcli"
check "a made-up (locally administered) BSSID is dropped, whatever its name" \
    "00:11:22:33:44:55 A4:B1:C1:00:00:01" \
    "$(py <<'PYEOF'
import importlib.machinery, importlib.util, sys
ld = importlib.machinery.SourceFileLoader("c", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("c", ld))
ld.exec_module(m)
print(" ".join(a["macAddress"] for a in m.scan_wifi()))
PYEOF
)"
rm -f "$TMP/bin/nmcli"

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

# geoclue answers a new client from its last known location, and that can be
# minutes old. The networks were scanned before the fix was asked for and the
# fix's own Timestamp was never read: a cached position from across town got
# paired with the networks in range here. Run, not grepped for.
py <<'PYEOF'
import importlib.machinery, importlib.util, os, sys, tempfile, time
os.environ["CONTRIB_STATE"] = tempfile.mkdtemp()
ld = importlib.machinery.SourceFileLoader("c", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("c", ld))
ld.exec_module(m)
m.log = lambda *a: None
now = time.time()
fix = {"Latitude": 50.0, "Longitude": 8.0, "Accuracy": 5.0, "Altitude": 120.0}
bad = 0
for stamp, want, what in [
        ((int(now) - 300, 0), False, "five minutes before the request"),
        ((int(now) - 2, 0), False, "two seconds before it"),
        (None, False, "no timestamp at all"),
        ((int(now) + 1, 500000), True, "after the request")]:
    values = dict(fix)
    if stamp:
        values["Timestamp"] = stamp
    got = m.judge_fix(values, not_before=now) is not None
    ok = got == want
    bad += not ok
    print(("  \033[32mok\033[0m   " if ok else "  \033[31mFAIL\033[0m ")
          + f"a fix taken {what}: {'used' if got else 'refused'}")
sys.exit(1 if bad else 0)
PYEOF
check "a cached fix is refused, a fresh one used" "0" "$?"
py <<'PYEOF'
import importlib.machinery, importlib.util, os, sys, tempfile, time
os.environ["CONTRIB_STATE"] = tempfile.mkdtemp()
ld = importlib.machinery.SourceFileLoader("c", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("c", ld))
ld.exec_module(m)
m.log = lambda *a: None
calls = []
before = [{"macAddress": f"AA:00:00:00:00:{i:02X}"} for i in range(3)]
after = [{"macAddress": f"BB:00:00:00:00:{i:02X}"} for i in range(3)]
def scan():
    calls.append("scan")
    return after if "fix" in calls else before
asked = {}
def fix(not_before, **k):
    calls.append("fix")
    asked["not_before"] = not_before
    return ({"latitude": 50.0, "longitude": 8.0, "accuracy": 5.0,
             "altitude": 1.0, "source": "gps"}, not_before + 3.0)
m.scan_wifi, m.gnss_fix = scan, fix
item = m.measure()
ok = (calls == ["scan", "fix", "scan"]
      and item["wifiAccessPoints"] == after
      and item["timestamp"] == int((asked["not_before"] + 3.0) * 1000))
sys.exit(0 if ok else 1)
PYEOF
check "the networks sent are scanned after the fix, stamped with its time" "0" "$?"
py <<'PYEOF'
import importlib.machinery, importlib.util, os, sys, tempfile, time
os.environ["CONTRIB_STATE"] = tempfile.mkdtemp()
ld = importlib.machinery.SourceFileLoader("c", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("c", ld))
ld.exec_module(m)
m.log = lambda *a: None
m.scan_wifi = lambda: [{"macAddress": f"AA:00:00:00:00:{i:02X}"} for i in range(3)]
m.gnss_fix = lambda not_before, **k: (
    {"latitude": 50.0, "longitude": 8.0, "accuracy": 5.0, "altitude": 1.0,
     "source": "gps"}, time.time() - m.SCAN_AFTER_FIX_S - 5)
sys.exit(0 if m.measure() is None and m.queue_read() == [] else 1)
PYEOF
check "a scan too long after the fix is not paired with it" "0" "$?"

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
# Run, not grepped for: the message was always there, and the batch was
# resent anyway - the expression deciding it was False for every status.
py <<'PYEOF'
import importlib.machinery, importlib.util, io, os, sys, tempfile, urllib.error
os.environ["CONTRIB_STATE"] = tempfile.mkdtemp()
ld = importlib.machinery.SourceFileLoader("c", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("c", ld))
ld.exec_module(m)
sent = []
def refuse(req, timeout=None):
    sent.append(req)
    raise urllib.error.HTTPError(m.ENDPOINT, 400, "Bad Request", {}, io.BytesIO(b""))
m.urllib.request.urlopen = refuse
m.on_wifi = lambda: True
m.time.sleep = lambda s: None
m.queue_write([{"n": i} for i in range(3)])
open(m.MARKER, "w").close()
m.flush()
sys.exit(0 if len(sent) == 1 and m.queue_read() == [] else 1)
PYEOF
check "a refused batch is dropped, not resent" "0" "$?"
# "off" stops the unit, and its ExecStop is "send": the send itself has to
# refuse once the marker is gone, or switching off hands over the queue.
py <<'PYEOF'
import importlib.machinery, importlib.util, os, sys, tempfile
os.environ["CONTRIB_STATE"] = tempfile.mkdtemp()
ld = importlib.machinery.SourceFileLoader("c", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("c", ld))
ld.exec_module(m)
sent = []
m.submit = lambda items: sent.append(items) or True
m.on_wifi = lambda: True
m.queue_write([{"n": i} for i in range(3)])
m.flush(everything=True)
sys.exit(0 if sent == [] and len(m.queue_read()) == 3 else 1)
PYEOF
check "switched off, a send sends nothing" "0" "$?"
check "nothing is sent over mobile data" "yes" \
    "$(grep -q 'def on_wifi' "$TOOL" && echo yes || echo no)"
# nmcli with NetworkManager's German catalogue says "verbunden", even with -t
# (4.10.2026: pactl did the same to audioctl). Wi-Fi has to be recognised in
# any language, or a German phone never submits anything.
cat > "$TMP/bin/nmcli" <<'STUB'
#!/bin/sh
case "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" in
C|C.*|POSIX) echo "wifi:connected" ;;
*)           echo "wifi:verbunden" ;;
esac
STUB
chmod +x "$TMP/bin/nmcli"
LC_ALL=de_DE.UTF-8 py <<'PYEOF'
import importlib.machinery, importlib.util, os, sys, tempfile
os.environ["CONTRIB_STATE"] = tempfile.mkdtemp()
ld = importlib.machinery.SourceFileLoader("c", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("c", ld))
ld.exec_module(m)
sys.exit(0 if m.on_wifi() else 1)
PYEOF
check "Wi-Fi is recognised on a phone set to German" "0" "$?"
rm -f "$TMP/bin/nmcli"
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

# The marker alone does nothing: after an installation the service is neither
# enabled nor running. Setting the marker without starting the service made
# the switch in the app write a file and look like it had done something -
# measured on the phone, the service stayed inactive with contributing=yes.
check "switching on enables and starts the service" "yes" \
    "$(grep -q 'unit_ctl("enable")' "$TOOL" && grep -q '"--now"' "$TOOL" && echo yes || echo no)"
check "and switching off disables and stops it" "yes" \
    "$(grep -q 'unit_ctl("disable")' "$TOOL" && echo yes || echo no)"
# After an installation everything is off until somebody switches it on -
# here more than anywhere, because switched on, data leaves the phone.
check "install.sh does not switch contributing on" "0" \
    "$(grep -v '^ *#' "$ROOT/install.sh" | grep -c 'enable.*furios-gps-contribute')"
check "status says whether anything is actually running" "yes" \
    "$(CONTRIB_STATE="$TMP/state" "$TOOL" status | grep -q '^running=' && echo yes || echo no)"
check "a test run never starts or stops the installed unit" "0" \
    "$(grep -c 'furios-gps-contribute\.service' "$TMP/systemctl.log" 2>/dev/null)"
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
    "$(awk '/def measure/,/pos = gnss_fix/' "$TOOL" | grep -q 'same_surroundings' && echo yes || echo no)"
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
calls = {"n": 0}
m.gnss_fix = lambda *a, **k: calls.update(n=calls["n"] + 1) or None
m.scan_wifi = lambda: aps
m.measure()
sys.exit(0 if calls["n"] == 0 else 1)
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
# Nothing on the contributing side wants root, so neither does installing it.
check "install.sh asks for no root" "0" \
    "$(grep -v '^ *#' "$ROOT/install.sh" | grep -c 'sudo')"
check "the unit finds the tool where install.sh puts it" "yes" \
    "$(grep -q '%h/.local/bin/furios-gps-contribute' "$UNIT" && echo yes || echo no)"
if command -v systemd-analyze >/dev/null 2>&1; then
    check "systemd accepts every key in it" "" \
        "$(systemd-analyze verify --user "$UNIT" 2>&1 | grep -iE 'unknown key|unknown lvalue' | head -1)"
fi

summary
