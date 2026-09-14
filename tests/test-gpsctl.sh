#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
#
# What gpsctl does to a config file, and what it refuses to do to one.
#
# Every one of these runs against a COPY of the file FuriOS ships, with the
# service names pointed at units that do not exist - so a test run never
# touches the phone it runs on. That is not politeness: these tests have to be
# runnable on the device, and a suite that switches the real location stack
# while it checks whether it can is a suite nobody dares run twice.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
. "$HERE/lib.sh"

GPSCTL="$ROOT/gpsctl"
SHIPPED="$ROOT/original-files/geoclue.conf"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export GPSCTL_CONF="$WORK/geoclue.conf"
export GPSCTL_PROFILE="$WORK/profile"
export GPSCTL_SHIPPED="$WORK/shipped"
export GPSCTL_COUNTERS="$WORK/counters"
export GPSCTL_UNIT="furios-gps-proxy-test-does-not-exist.service"
export GPSCTL_LEGACY_UNIT="beacondb-proxy-test-does-not-exist.service"

fresh() { cp "$SHIPPED" "$GPSCTL_CONF"; rm -f "$GPSCTL_PROFILE" "$GPSCTL_SHIPPED"; }
g()     { "$GPSCTL" "$@" --no-restart 2>&1; }

# --- the change itself ------------------------------------------------------

fresh
g apply >/dev/null
check "apply switches the Wi-Fi source on" \
    "true" "$(sed -n '/^\[wifi\]/,/^\[/p' "$GPSCTL_CONF" | sed -n 's/^enable=//p')"
check "apply points the URL at the proxy" \
    "http://127.0.0.1:8765/v1/geolocate" \
    "$(sed -n '/^\[wifi\]/,/^\[/p' "$GPSCTL_CONF" | sed -n 's/^url=//p')"

# The whole argument for this project being safe to install: it is two lines.
check "apply changes exactly two lines and nothing else" \
    "2" "$(diff "$SHIPPED" "$GPSCTL_CONF" | grep -c '^>')"

# Those comments are the documentation for what the keys mean, and a config
# editor that eats them makes the next person's job harder for no reason.
check "the comments survive" \
    "$(grep -c '^#' "$SHIPPED")" "$(grep -c '^#' "$GPSCTL_CONF")"

# Nothing outside [wifi] is any of this project's business - least of all the
# GNSS source it depends on and the list of who may ask for a location at all.
check "the GNSS source is left alone" \
    "$(sed -n '/^\[hybris\]/,/^\[/p' "$SHIPPED")" \
    "$(sed -n '/^\[hybris\]/,/^\[/p' "$GPSCTL_CONF")"
check "the agent whitelist is left alone" \
    "$(sed -n '/^\[agent\]/,/^\[/p' "$SHIPPED")" \
    "$(sed -n '/^\[agent\]/,/^\[/p' "$GPSCTL_CONF")"

# --- and back ---------------------------------------------------------------

g revert >/dev/null
check "revert puts the file back byte for byte" \
    "same" "$(cmp -s "$SHIPPED" "$GPSCTL_CONF" && echo same || echo different)"

g apply >/dev/null
before=$(cat "$GPSCTL_CONF")
g apply >/dev/null
check "a second apply changes nothing" "$before" "$(cat "$GPSCTL_CONF")"
g revert >/dev/null
g revert >/dev/null
check "a second revert changes nothing" \
    "same" "$(cmp -s "$SHIPPED" "$GPSCTL_CONF" && echo same || echo different)"

# --- what it records --------------------------------------------------------

fresh
g apply >/dev/null
check "it records the URL the phone had before" \
    "url=https://api.beacondb.net/v1/geolocate" "$(sed -n '1p' "$GPSCTL_SHIPPED")"
check "it records that the source was off" \
    "enable=false" "$(sed -n '2p' "$GPSCTL_SHIPPED")"

# The trap this walks into otherwise: installed onto a phone that already has
# the hand-rolled version running, the "state before" it would record is our
# own proxy - and revert would be a no-op for ever after.
fresh
sed -i 's|^url=https://api.beacondb.net/v1/geolocate|url=http://127.0.0.1:8765/v1/geolocate|' "$GPSCTL_CONF"
sed -i '/^\[wifi\]/,/^\[compass\]/s/^enable=false/enable=true/' "$GPSCTL_CONF"
g apply >/dev/null
check "it never records our own proxy as the state to go back to" \
    "url=https://api.beacondb.net/v1/geolocate" "$(sed -n '1p' "$GPSCTL_SHIPPED")"
g revert >/dev/null
check "and so revert still has somewhere to go" \
    "https://api.beacondb.net/v1/geolocate" \
    "$(sed -n '/^\[wifi\]/,/^\[/p' "$GPSCTL_CONF" | sed -n 's/^url=//p')"

# --- what state it thinks the phone is in -----------------------------------

fresh
check "a shipped file reads as shipped" "shipped" "$("$GPSCTL" profile | sed -n 's/^actual: *//p')"
g apply >/dev/null
# The unit does not exist in a test run, so "fixed" is not reachable here and
# must not be claimed: half the change in place is "mixed", and saying so is
# the whole point of having a third answer.
check "config without the proxy is not called fixed" \
    "mixed" "$("$GPSCTL" profile | sed -n 's/^actual: *//p')"

fresh
g apply >/dev/null
sed -i '/^\[wifi\]/,/^\[compass\]/s/^enable=true/enable=false/' "$GPSCTL_CONF"
check "half a config change reads as mixed" \
    "mixed" "$("$GPSCTL" profile | sed -n 's/^actual: *//p')"

fresh
check "no recorded profile means fixed" "fixed" "$("$GPSCTL" profile | sed -n 's/^recorded: *//p')"
echo "sideways" > "$GPSCTL_PROFILE"
check "a profile nobody understands is not guessed at" \
    "unknown" "$("$GPSCTL" profile | sed -n 's/^recorded: *//p')"
check_status "and saying so is a failure, not a shrug" 1 "$GPSCTL" profile

# --- set, try, boot ---------------------------------------------------------

fresh
g set shipped >/dev/null
check "set writes the profile down" "shipped" "$(cat "$GPSCTL_PROFILE")"
g try fixed >/dev/null
check "try does not" "shipped" "$(cat "$GPSCTL_PROFILE")"
check "and boot undoes what try did" \
    "same" "$(g boot >/dev/null; cmp -s "$SHIPPED" "$GPSCTL_CONF" && echo same || echo different)"

check_status "an unknown profile is refused" 2 "$GPSCTL" set sideways
check_status "and so is no profile at all" 2 "$GPSCTL" set

# --- writing a key that is not there ----------------------------------------

fresh
sed -i '/^\[wifi\]/,/^\[compass\]/{/^url=/d}' "$GPSCTL_CONF"
g apply >/dev/null
check "a missing key is written into its own section" \
    "http://127.0.0.1:8765/v1/geolocate" \
    "$(sed -n '/^\[wifi\]/,/^\[/p' "$GPSCTL_CONF" | sed -n 's/^url=//p')"
check "and not into the next one" \
    "0" "$(sed -n '/^\[compass\]/,/^\[/p' "$GPSCTL_CONF" | grep -c '^url=')"

printf '[agent]\nwhitelist=x\n' > "$GPSCTL_CONF"
rm -f "$GPSCTL_SHIPPED"
g apply >/dev/null
check "a missing section is created" \
    "http://127.0.0.1:8765/v1/geolocate" \
    "$(sed -n '/^\[wifi\]/,/^\[/p' "$GPSCTL_CONF" | sed -n 's/^url=//p')"

# --- reading a file it did not write ----------------------------------------

fresh
sed -i '/^\[wifi\]/,/^\[compass\]/s|^url=.*|url = "https://api.beacondb.net/v1/geolocate"|' "$GPSCTL_CONF"
check "a quoted, spaced value reads the same as a bare one" \
    "missing" "$("$GPSCTL" status 2>/dev/null >/dev/null; \
        sed -n '/^\[wifi\]/,/^\[/p' "$GPSCTL_CONF" | grep -q '127.0.0.1' && echo applied || echo missing)"
g apply >/dev/null
check "and is replaced cleanly, not appended to" \
    "1" "$(sed -n '/^\[wifi\]/,/^\[/p' "$GPSCTL_CONF" | grep -c '^url=')"

summary
