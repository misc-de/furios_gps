#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
# Removes everything this project installed and puts geoclue's config back.
set -e
cd "$(dirname "$0")"

# Revert first - afterwards gpsctl is gone and geoclue.conf would stay pointed
# at a proxy that no longer exists, which is a phone with no Wi-Fi location at
# all and nothing installed to explain why.
sudo /usr/local/bin/gpsctl revert || true

sudo systemctl disable --now furios-gps-proxy.service 2>/dev/null || true
sudo systemctl disable --now furios-gps-fix.service 2>/dev/null || true
systemctl --user disable --now furios-gps-contribute.service >/dev/null 2>&1 || true
rm -f "$HOME/.config/systemd/user/furios-gps-contribute.service"
sudo rm -f /usr/local/bin/furios-gps-contribute /usr/bin/furios-gps-contribute
sudo rm -f /etc/systemd/system/furios-gps-proxy.service \
           /etc/systemd/system/furios-gps-fix.service \
           /usr/local/bin/gpsctl \
           /usr/local/bin/furios-gps-proxy \
           /usr/share/polkit-1/actions/de.misc-de.gpsctl.policy
# The recorded profile and the recorded shipped values go too: they describe a
# package that is no longer here, and leaving them means a reinstall would
# "remember" a choice nobody made this time round.
sudo rm -f /etc/furios-gps-fix.profile /etc/furios-gps-fix.shipped
sudo systemctl daemon-reload

echo
echo "Removed, and geoclue is back to what it shipped with."
echo
echo "Note what that means: the Wi-Fi source is off again, so geoclue works out"
echo "where this phone is from its IP address - on mobile data, the carrier's"
echo "exit node. That is the state the phone came in, not a private one."
