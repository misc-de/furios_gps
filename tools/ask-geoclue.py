#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
"""Asks geoclue for a position over one held D-Bus connection, and reports only
whether there is one and how accurate - never where."""
import sys
from gi.repository import Gio, GLib

WAIT = int(sys.argv[1]) if len(sys.argv) > 1 else 60
BUS = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)


def proxy(path, iface):
    return Gio.DBusProxy.new_sync(BUS, Gio.DBusProxyFlags.NONE, None,
                                  "org.freedesktop.GeoClue2", path, iface, None)


mgr = proxy("/org/freedesktop/GeoClue2/Manager", "org.freedesktop.GeoClue2.Manager")
path = mgr.call_sync("GetClient", None, Gio.DBusCallFlags.NONE, -1, None).unpack()[0]
print(f"Client: {path}")

props = proxy(path, "org.freedesktop.DBus.Properties")
props.call_sync("Set", GLib.Variant("(ssv)", ("org.freedesktop.GeoClue2.Client",
                "DesktopId", GLib.Variant("s", "gpsctl-messung"))),
                Gio.DBusCallFlags.NONE, -1, None)
props.call_sync("Set", GLib.Variant("(ssv)", ("org.freedesktop.GeoClue2.Client",
                "RequestedAccuracyLevel", GLib.Variant("u", 8))),
                Gio.DBusCallFlags.NONE, -1, None)

client = proxy(path, "org.freedesktop.GeoClue2.Client")
loop = GLib.MainLoop()
state = {"done": False}


def on_signal(_p, _s, signal, params):
    if signal != "LocationUpdated":
        return
    loc = params.unpack()[1]
    lp = proxy(loc, "org.freedesktop.DBus.Properties")
    acc = lp.call_sync("Get", GLib.Variant("(ss)",
                       ("org.freedesktop.GeoClue2.Location", "Accuracy")),
                       Gio.DBusCallFlags.NONE, -1, None).unpack()[0]
    print(f"POSITION - accuracy {acc:.0f} m (coordinates not printed)")
    state["done"] = True
    loop.quit()


client.connect("g-signal", on_signal)
try:
    client.call_sync("Start", None, Gio.DBusCallFlags.NONE, 15000, None)
    print("Start: ok")
except GLib.Error as e:
    print(f"Start: {e.message}")
    sys.exit(1)

GLib.timeout_add_seconds(WAIT, lambda: (loop.quit(), False)[1])
loop.run()
try:
    client.call_sync("Stop", None, Gio.DBusCallFlags.NONE, 5000, None)
except GLib.Error:
    pass
if not state["done"]:
    print(f"KEINE Position nach {WAIT}s")
    sys.exit(2)
