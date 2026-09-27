#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
# Removes everything this project installed - the contribution tool, and the
# retired location filter where an older version left it behind.
set -e
cd "$(dirname "$0")"

# Switched off first: "off" drops the marker, and stopping the service would
# otherwise hand over the queue on its way out.
for c in "$HOME/.local/bin/furios-gps-contribute" \
         /usr/local/bin/furios-gps-contribute; do
    [ -x "$c" ] && { "$c" off >/dev/null 2>&1 || true; break; }
done
systemctl --user disable --now furios-gps-contribute.service >/dev/null 2>&1 || true
rm -f "$HOME/.config/systemd/user/furios-gps-contribute.service" \
      "$HOME/.local/bin/furios-gps-contribute"
systemctl --user daemon-reload 2>/dev/null || true

# The retired filter, as versions before 27.9.2026 installed it. Only with
# something actually there does this ask for root.
old="/usr/local/bin/gpsctl /usr/local/bin/furios-gps-proxy
     /usr/local/bin/furios-gps-contribute
     /etc/systemd/system/furios-gps-proxy.service
     /etc/systemd/system/furios-gps-fix.service
     /usr/share/polkit-1/actions/de.misc-de.gpsctl.policy
     /etc/furios-gps-fix.profile /etc/furios-gps-fix.shipped"
found=
for f in $old; do [ -e "$f" ] && found=yes; done
if [ -n "$found" ]; then
    # Revert first - afterwards gpsctl is gone and geoclue.conf would stay
    # pointed at a proxy that no longer exists: no Wi-Fi location at all.
    [ -x /usr/local/bin/gpsctl ] && sudo /usr/local/bin/gpsctl revert || true
    sudo systemctl disable --now furios-gps-proxy.service 2>/dev/null || true
    sudo systemctl disable --now furios-gps-fix.service 2>/dev/null || true
    # shellcheck disable=SC2086
    sudo rm -f $old
    sudo systemctl daemon-reload
    echo "The retired location filter is removed, geoclue.conf is back to"
    echo "what the package shipped."
fi

echo
echo "Removed."
