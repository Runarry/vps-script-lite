#!/usr/bin/env python3
"""Expose an empty systemd-resolved link on an isolated D-Bus daemon.

This fixture is intentionally small: it implements only the Manager.GetLink
method and Link DNS/DNSEx properties used by sing-box's Linux local resolver.
It requires the distro's python3-dbus package (or an extracted equivalent on
PYTHONPATH) and must be pointed at a private bus through --address.
"""

from __future__ import annotations

import argparse
import signal

import dbus
import dbus.service
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib


SERVICE = "org.freedesktop.resolve1"
MANAGER_PATH = "/org/freedesktop/resolve1"
LINK_PATH = "/org/freedesktop/resolve1/link/_fixture"
MANAGER_INTERFACE = "org.freedesktop.resolve1.Manager"
LINK_INTERFACE = "org.freedesktop.resolve1.Link"
PROPERTIES_INTERFACE = "org.freedesktop.DBus.Properties"


class Manager(dbus.service.Object):
    @dbus.service.method(MANAGER_INTERFACE, in_signature="i", out_signature="o")
    def GetLink(self, _ifindex: int) -> dbus.ObjectPath:  # noqa: N802 - D-Bus API
        return dbus.ObjectPath(LINK_PATH)


class Link(dbus.service.Object):
    @staticmethod
    def properties() -> dict[str, dbus.Array]:
        return {
            "DNS": dbus.Array([], signature="(iay)"),
            "DNSEx": dbus.Array([], signature="(iayqs)"),
        }

    @dbus.service.method(PROPERTIES_INTERFACE, in_signature="ss", out_signature="v")
    def Get(self, interface: str, name: str) -> object:  # noqa: N802 - D-Bus API
        if interface != LINK_INTERFACE or name not in self.properties():
            raise dbus.exceptions.DBusException(
                "Unknown property", name="org.freedesktop.DBus.Error.UnknownProperty"
            )
        return self.properties()[name]

    @dbus.service.method(PROPERTIES_INTERFACE, in_signature="s", out_signature="a{sv}")
    def GetAll(self, interface: str) -> dict[str, dbus.Array]:  # noqa: N802 - D-Bus API
        if interface != LINK_INTERFACE:
            return {}
        return self.properties()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--address", required=True)
    parser.add_argument("--ready", required=True)
    args = parser.parse_args()

    DBusGMainLoop(set_as_default=True)
    bus = dbus.bus.BusConnection(args.address)
    name = dbus.service.BusName(SERVICE, bus=bus, do_not_queue=True)
    manager = Manager(bus, MANAGER_PATH)
    link = Link(bus, LINK_PATH)
    loop = GLib.MainLoop()

    def stop(_signum: int, _frame: object) -> None:
        loop.quit()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    with open(args.ready, "w", encoding="utf-8") as stream:
        stream.write("ready\n")
    loop.run()
    # Keep service objects and the claimed name alive until after loop exit.
    _ = (name, manager, link)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
