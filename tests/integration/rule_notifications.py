"""Drive the rule-update dialog through the desktop notification D-Bus protocol."""
import asyncio
import json
import os
from pathlib import Path
import sys
import tempfile

from dbus_next.aio import MessageBus
from dbus_next.service import ServiceInterface, method, signal

from tests.support import ROOT


class Notifications(ServiceInterface):
    def __init__(self):
        super().__init__("org.freedesktop.Notifications")
        self.count = 0

    @method()
    def GetCapabilities(self) -> 'as':
        return ["actions", "body"]

    @method()
    def GetServerInformation(self) -> 'ssss':
        return ["fixture", "project", "1", "1.2"]

    @method()
    def Notify(self, app: 's', replaces: 'u', icon: 's', summary: 's', body: 's',
               actions: 'as', hints: 'a{sv}', timeout: 'i') -> 'u':
        self.count += 1
        identity = self.count
        if "default" in actions:
            asyncio.get_running_loop().call_later(0.1, self.ActionInvoked, identity, "default")
        return identity

    @method()
    def CloseNotification(self, identity: 'u'):
        self.NotificationClosed(identity, 3)

    @signal()
    def ActionInvoked(self, identity: 'u', action: 's') -> 'us':
        return [identity, action]

    @signal()
    def NotificationClosed(self, identity: 'u', reason: 'u') -> 'uu':
        return [identity, reason]


async def main():
    bus = await MessageBus().connect()
    service = Notifications()
    bus.export("/org/freedesktop/Notifications", service)
    await bus.request_name("org.freedesktop.Notifications")
    try:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            status = root / "status.json"
            pending = {"id": "a" * 64, "created": "2026-01-01T00:00:00+00:00"}
            status.write_text(json.dumps({"active": None, "pending": pending}))
            chooser = root / "rofi"
            chooser.write_text(f"#!{sys.executable}\n" + '''
import json, os, pathlib, sys
root = pathlib.Path(os.environ["FIXTURE_ROOT"])
(root / "dialog.json").write_text(json.dumps({"args": sys.argv[1:], "choices": sys.stdin.read().splitlines()}))
print(os.environ["FIXTURE_CHOICE"])
''')
            manager = root / "systemctl"
            manager.write_text(f"#!{sys.executable}\n" + '''
import json, os, pathlib, sys
root = pathlib.Path(os.environ["FIXTURE_ROOT"])
path = root / "status.json"
state = json.loads(path.read_text())
assert sys.argv[1:] == ["start", "site-network-rules-apply@" + state["pending"]["id"] + ".service"]
(root / "applied").write_text(state["pending"]["id"])
path.write_text(json.dumps({"active": state["pending"], "pending": None}))
''')
            chooser.chmod(0o755)
            manager.chmod(0o755)
            for choice in ("0", "1"):
                process = await asyncio.create_subprocess_exec(sys.executable,
                    str(ROOT / "scripts/desktop/network_rules.py"), "--status", str(status),
                    "--rofi", str(chooser), "--systemctl", str(manager),
                    env=os.environ | {"FIXTURE_ROOT": str(root), "FIXTURE_CHOICE": choice})
                assert await asyncio.wait_for(process.wait(), timeout=20) == 0
                dialog = json.loads((root / "dialog.json").read_text())
                selected = dialog["args"][dialog["args"].index("-selected-row") + 1]
                assert selected == "0" and dialog["choices"][0] == "稍后"
                current = json.loads(status.read_text())
                if choice == "0":
                    assert current["pending"] == pending and current["active"] is None
                    assert not (root / "applied").exists()
                else:
                    assert current["active"] == pending and current["pending"] is None
                    assert (root / "applied").read_text() == pending["id"]
            print("Notification action → Rofi postponement and confirmed application passed")
    finally:
        bus.disconnect()


if __name__ == "__main__":
    asyncio.run(main())
