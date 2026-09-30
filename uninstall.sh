#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
# Removes everything this project installed, and everything it wrote while it
# ran - the contribution tool, its queue and counters, the Firefox prefs, and
# the retired location filter where an older version left it behind. What is
# left afterwards is a phone a fresh install.sh cannot tell from a new one.
set -e
cd "$(dirname "$0")"

# Where both tools keep their state: markers, queue, counters.
STATE_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/furios-gps
USER_UNITS=$HOME/.config/systemd/user

# Switched off first: "off" drops the marker, and stopping the service would
# otherwise hand over the queue on its way out. The copy in this checkout is
# the last resort: with the installed one already gone, "off" still has to run.
for c in "$HOME/.local/bin/furios-gps-contribute" \
         /usr/local/bin/furios-gps-contribute tools/furios-gps-contribute; do
    [ -x "$c" ] && { "$c" off >/dev/null 2>&1 || true; break; }
done
systemctl --user disable --now furios-gps-contribute.service >/dev/null 2>&1 || true
# The Firefox prefs come out of every profile before the tool that knows them
# goes; a profile open right now keeps its prefs.js values until it is closed
# and "furios-gps-firefox off" runs again - said, not hidden.
for c in "$HOME/.local/bin/furios-gps-firefox" /usr/bin/furios-gps-firefox \
         tools/furios-gps-firefox; do
    [ -x "$c" ] && { "$c" off || true; break; }
done
systemctl --user disable --now furios-gps-firefox.path furios-gps-firefox.service \
    >/dev/null 2>&1 || true
# The enable links by hand as well: without a user manager to talk to (an ssh
# login, a session that is going down) "disable" fails, and a link left in
# default.target.wants is a unit that comes back with the next install.
for u in furios-gps-contribute.service furios-gps-firefox.service \
         furios-gps-firefox.path; do
    rm -f "$USER_UNITS"/*.wants/"$u"
done
# The installed files go back to what install.sh found before its first run,
# from the record it wrote then (install-record.sh explains the format): gone
# where nothing was, the earlier file where there was one, and left alone
# where somebody changed ours since. Without a record - an install from
# before 30.9.2026 - they are removed by name, as uninstall.sh always did,
# and it says so rather than pretending to know.
REC_DIR=$STATE_DIR/install-record
. ./install-record.sh
if rec_exists; then
    rec_restore
else
    echo "No install record (installed before 30.9.2026): removing the files"
    echo "by name - what was at those paths before cannot be known."
    for u in furios-gps-contribute.service furios-gps-firefox.service \
             furios-gps-firefox.path; do
        rm -f "$USER_UNITS/$u"
    done
    rm -f "$HOME/.local/bin/furios-gps-contribute" \
          "$HOME/.local/bin/furios-gps-firefox"
fi
rm -f "$HOME"/.local/bin/__pycache__/furios-gps-contributecpython-*.pyc \
      "$HOME"/.local/bin/__pycache__/furios-gps-firefoxcpython-*.pyc
rmdir "$HOME/.local/bin/__pycache__" 2>/dev/null || true
systemctl --user daemon-reload 2>/dev/null || true

# What the tools wrote while they ran: the two markers, the queue that was
# never sent (it is not sent now either - uninstalling is not consenting),
# the counters, and the temporary siblings of all of them. A reinstall starts
# at zero, switched off, the way it does on a new phone.
# The install record goes with it - unless rec_restore kept it because a file
# that was there before our install could not be put back; then it stays,
# and rec_restore has said where.
if [ -d "$REC_DIR" ]; then
    find "$STATE_DIR" -mindepth 1 -maxdepth 1 ! -name install-record -exec rm -rf {} +
else
    rm -rf "$STATE_DIR"
fi
# user.js and prefs.js are written through a temporary file beside them; one
# left by an interrupted write is ours.
rm -f "$HOME"/.mozilla/firefox/*/*.furios-gps.tmp

# The retired filter, as versions before 27.9.2026 installed it. Only with
# something actually there does this ask for root.
GEOCLUE_CONF=/etc/geoclue/geoclue.conf
PROXY_URL=http://127.0.0.1:8765/v1/geolocate
old="/usr/local/bin/gpsctl /usr/local/bin/furios-gps-proxy
     /usr/local/bin/furios-gps-contribute
     /etc/systemd/system/furios-gps-proxy.service
     /etc/systemd/system/furios-gps-fix.service
     /etc/systemd/system/multi-user.target.wants/furios-gps-proxy.service
     /etc/systemd/system/multi-user.target.wants/furios-gps-fix.service
     /usr/share/polkit-1/actions/de.misc-de.gpsctl.policy
     /etc/furios-gps-fix.profile /etc/furios-gps-fix.shipped"
found=
for f in $old; do [ -e "$f" ] || [ -L "$f" ] && found=yes; done
grep -qF "$PROXY_URL" "$GEOCLUE_CONF" 2>/dev/null && found=yes
if [ -n "$found" ]; then
    # Revert first - afterwards gpsctl is gone and geoclue.conf would stay
    # pointed at a proxy that no longer exists: no Wi-Fi location at all.
    [ -x /usr/local/bin/gpsctl ] && sudo /usr/local/bin/gpsctl revert || true
    # And where gpsctl is already gone but geoclue.conf still names the
    # proxy, the two keys gpsctl wrote go back by hand, in [wifi] only: to
    # what gpsctl recorded as shipped, or to what geoclue 2.7.1 ships.
    if grep -qF "$PROXY_URL" "$GEOCLUE_CONF" 2>/dev/null; then
        url=$(sed -n 's/^url=//p' /etc/furios-gps-fix.shipped 2>/dev/null | head -1)
        enable=$(sed -n 's/^enable=//p' /etc/furios-gps-fix.shipped 2>/dev/null | head -1)
        # gpsctl's record is the only source that knows; without it these are
        # geoclue 2.7.1's shipped values - a fallback, and said as one.
        if [ -z "$url" ] || [ -z "$enable" ]; then
            echo "No record of geoclue.conf before the filter (/etc/furios-gps-fix.shipped):"
            echo "putting back what geoclue 2.7.1 ships for the keys that are missing."
        fi
        url=${url:-https://api.beacondb.net/v1/geolocate}
        enable=${enable:-false}
        sudo sed -i "/^\[wifi\]/,/^\[/{s|^url=${PROXY_URL}\$|url=${url}|;s|^enable=true\$|enable=${enable}|}" \
            "$GEOCLUE_CONF"
    fi
    sudo systemctl disable --now furios-gps-proxy.service 2>/dev/null || true
    sudo systemctl disable --now furios-gps-fix.service 2>/dev/null || true
    # shellcheck disable=SC2086
    sudo rm -f $old
    # gpsctl's temporary file beside geoclue.conf, if a write was cut short,
    # and the proxy's counters in /run (a reboot takes those as well).
    sudo rm -rf /etc/geoclue/.gpsctl.* /run/furios-gps-proxy
    sudo systemctl daemon-reload
    echo "The retired location filter is removed, geoclue.conf is back to"
    echo "what the package shipped."
fi

echo
echo "Removed."
