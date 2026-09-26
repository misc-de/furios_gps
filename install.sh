#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
# Installs gpsctl, the proxy, the boot unit and the polkit action. It does
# not switch the filter on - "gpsctl set fixed" does. Safe to re-run.
set -e
cd "$(dirname "$0")"

# /usr/local, not /usr: that is where a hand installation belongs, and it keeps
# this out of the way of the .deb. Installing both used to leave an "apt
# remove" behind with a unit in /etc pointing at a binary that was gone.
BIN=/usr/local/bin

# Before anything else: the hand-rolled ancestor of this package. Both want
# port 8765, and two services fighting over one port means the loser dies at
# every boot with nothing to show for it. Its script is left exactly where it
# is - taking somebody's file out from under them is not this installer's job.
LEGACY=beacondb-proxy.service
if systemctl cat "$LEGACY" >/dev/null 2>&1; then
    echo "0) the hand-rolled $LEGACY is here and wants the same port"
    sudo systemctl disable --now "$LEGACY" >/dev/null 2>&1 || true
    echo "   stopped and disabled. Its unit file and script are untouched;"
    echo "   remove them yourself once you are happy this replaces them."
fi

echo "1) programs"
sudo install -Dm755 gpsctl                 "$BIN/gpsctl"
sudo install -Dm755 tools/furios-gps-proxy "$BIN/furios-gps-proxy"
# Contributing back to beaconDB. Installed but never switched on: the tool
# does nothing without a marker the user has to place, so this only puts the
# option within reach.
sudo install -Dm755 tools/furios-gps-contribute "$BIN/furios-gps-contribute"
install -Dm644 systemd/furios-gps-contribute.service \
    "$HOME/.config/systemd/user/furios-gps-contribute.service"
systemctl --user daemon-reload 2>/dev/null || true
systemctl --user enable --now furios-gps-contribute.service >/dev/null 2>&1 || true

echo "2) units"
# The units ship with the package's paths in them; point them at these.
sed "s|^ExecStart=/usr/bin/furios-gps-proxy|ExecStart=$BIN/furios-gps-proxy|" \
    systemd/furios-gps-proxy.service | sudo tee \
    /etc/systemd/system/furios-gps-proxy.service >/dev/null
sudo chmod 644 /etc/systemd/system/furios-gps-proxy.service
sed "s|^ExecStart=/usr/bin/gpsctl|ExecStart=$BIN/gpsctl|" \
    systemd/furios-gps-fix.service | sudo tee \
    /etc/systemd/system/furios-gps-fix.service >/dev/null
sudo chmod 644 /etc/systemd/system/furios-gps-fix.service

echo "3) the polkit action"
# The action names the binary it is allowed to run, so it has to name THIS
# one. A policy pointing at /usr/bin while the app starts /usr/local/bin does
# not fail loudly - pkexec just refuses, and the switch looks broken.
sed "s|>/usr/bin/gpsctl<|>$BIN/gpsctl<|" polkit/de.misc-de.gpsctl.policy \
    | sudo tee /usr/share/polkit-1/actions/de.misc-de.gpsctl.policy >/dev/null
sudo chmod 644 /usr/share/polkit-1/actions/de.misc-de.gpsctl.policy

sudo systemctl daemon-reload
# The boot unit only replays a profile somebody recorded with "gpsctl set";
# with none recorded it does nothing, so enabling it switches nothing on.
sudo systemctl enable furios-gps-fix.service >/dev/null

# Not applied here: after an install every option is off until its owner
# turns it on - and this one rewrites geoclue.conf and starts a service.
# What an owner did turn on is kept: a running proxy gets the new code
# (try-restart starts nothing that is stopped), and "boot" replays a recorded
# profile and does nothing when there is none.
sudo systemctl try-restart furios-gps-proxy.service >/dev/null 2>&1 || true
sudo "$BIN/gpsctl" boot --quiet || true
echo
echo "Installed. Nothing has been switched on."
echo "Switch the filter on:            sudo gpsctl set fixed   (or the app, GPS page)"
echo "Check any time with:             gpsctl status"
echo "Watch one real query refused:    gpsctl probe"
