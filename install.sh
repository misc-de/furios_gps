#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
# Installs furios-gps-contribute, furios-gps-firefox and their user units - for this user, no root.
# It does not switch contributing on: "furios-gps-contribute on" does, or the
# switch in the app. Safe to re-run.
set -e
cd "$(dirname "$0")"

BIN=$HOME/.local/bin

echo "1) program"
install -Dm755 tools/furios-gps-contribute "$BIN/furios-gps-contribute"
install -Dm755 tools/furios-gps-firefox "$BIN/furios-gps-firefox"

echo "2) user unit"
install -Dm644 systemd/furios-gps-contribute.service \
    "$HOME/.config/systemd/user/furios-gps-contribute.service"
for u in furios-gps-firefox.service furios-gps-firefox.path; do
    install -Dm644 "systemd/$u" "$HOME/.config/systemd/user/$u"
done
systemctl --user daemon-reload 2>/dev/null || true
# A running service gets the new code; a stopped one stays stopped.
systemctl --user try-restart furios-gps-contribute.service >/dev/null 2>&1 || true

# The location filter this repository used to install is retired: geoclue
# 2.7.1-3+furios7 discards IP-derived positions itself. It is not removed
# here, because that needs root and rewrites geoclue.conf - uninstall.sh does.
if [ -e /usr/local/bin/gpsctl ] || [ -e /usr/bin/gpsctl ]; then
    echo
    echo "The retired location filter (gpsctl) is still installed."
    echo "./uninstall.sh removes it and puts geoclue.conf back; run install.sh"
    echo "again afterwards to keep contributing."
fi

echo
echo "Installed. Nothing has been switched on."
echo "Switch contributing on:  furios-gps-contribute on   (or the app, GPS page)"
echo "See what it would send:  furios-gps-contribute once --dry-run"
echo "Firefox/web apps wait for the GNSS fix:  furios-gps-firefox on"
