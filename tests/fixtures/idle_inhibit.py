"""Keep the Plasma ScreenSaver inhibition cookie's D-Bus connection alive."""
import signal
from pathlib import Path

import dbus
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

DBusGMainLoop(set_as_default=True)
bus = dbus.SessionBus()
screensaver = dbus.Interface(bus.get_object("org.freedesktop.ScreenSaver", "/ScreenSaver"),
                            "org.freedesktop.ScreenSaver")
cookie = screensaver.Inhibit("VM application test", "native keyboard interaction")
loop = GLib.MainLoop()
signal.signal(signal.SIGTERM, lambda *args: loop.quit())
signal.signal(signal.SIGINT, lambda *args: loop.quit())
Path("/run/user/1000/vm-idle-inhibited").touch()
try:
    loop.run()
finally:
    screensaver.UnInhibit(cookie)
    Path("/run/user/1000/vm-idle-inhibited").unlink(missing_ok=True)
