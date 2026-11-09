"""Exercise sending, provider failure and confinement together using the real services."""
import json
import shlex


def notification_smoke(machine, upstream, python):
    try:
        exercise_notifications(machine, upstream, python)
    except Exception as error:
        # This request uses the fixture's public device key, from the same
        # container as Apprise. Bark's response includes the APNs/TLS error.
        probe = """
import requests
response = requests.post('http://bark:8080/push', timeout=25,
                         json={'device_key': 'local', 'body': 'diagnostic'})
print(response.status_code, response.text)
"""
        captures = [
            (machine, "bark-response", f"docker exec site-apprise {python} -c {shlex.quote(probe)}"),
            (machine, "services", "journalctl -b -u haproxy -u docker-site-bark -u docker-site-apprise --no-pager -o short-precise"),
            (upstream, "simulator", "journalctl -b -u notification-fixture --no-pager -o short-precise"),
        ]
        for guest, name, command in captures:
            try:
                path = "/tmp/notification-" + name + ".log"
                status, _ = guest.execute("(" + command + ") > " + path + " 2>&1", timeout=40)
                guest.copy_from_machine(path, "notifications")
                print(f"Notification diagnostics: {name}, exit {status}, {guest.out_dir}/notifications")
            except Exception as diagnostic_error:
                error.add_note(f"Collecting notification {name}: {diagnostic_error}")
        raise


def exercise_notifications(machine, upstream, python):
    upstream.wait_for_unit("notification-fixture.service")
    machine.wait_for_unit("haproxy.service")
    machine.wait_for_unit("docker-site-apprise.service")
    machine.wait_for_unit("docker-site-bark.service")
    cases = (
        (["中文正文：单参数"], "中文正文：单参数", "bark", "bark", "1107"),
        (["标题", "中文正文：双参数"], "中文正文：双参数", "标题", "标题", "1107"),
        (["工作", "标题", "中文正文：三参数"], "中文正文：三参数", "标题", "工作", "1107"),
        (["工作", "标题", "中文正文：四参数", "glass"], "中文正文：四参数", "标题", "工作", "glass.caf"),
    )
    for index, (arguments, body, title, group, sound) in enumerate(cases):
        command = "su -s /bin/sh sender -c " + shlex.quote(shlex.join(["bark", *arguments]))
        # Readiness is the first real delivery through the ordinary user's socket.
        output = machine.wait_until_succeeds(command, timeout=180) if index == 0 else machine.succeed(command)
        result = json.loads(output)
        assert result["channels"][0]["delivered"], result
        events = [json.loads(line) for line in upstream.succeed("cat /run/notification-fixture/events.jsonl").splitlines()]
        delivered = [event for event in events if event["status"] == 200
                     and event["body"].get("aps", {}).get("alert", {}).get("body") == body]
        assert delivered, (body, events)
        for event in delivered:
            payload = event["body"]["aps"]
            assert (payload["alert"]["title"], payload["alert"]["body"]) == (title, body), payload
            assert payload["thread-id"] == group and payload["sound"] == sound, payload
    machine.succeed("su -s /bin/sh sender -c 'site-notify send --channel wecom --title 测试 企业微信'")
    # Retry only a bounded number of times and preserve the nonzero delivery result.
    upstream.succeed("echo 3 > /run/notification-fixture/failures")
    code, output = machine.execute("su -s /bin/sh sender -c 'bark 暂时失败'")
    delivery = json.loads(output)
    assert code != 0 and delivery["channels"][0]["attempts"] == 3, delivery
    machine.succeed("su -s /bin/sh sender -c 'bark 已恢复'")

    machine.fail("su -s /bin/sh outsider -c 'bark 无发送权限'")
    machine.fail("su -s /bin/sh sender -c 'cat /run/notification-fixture-token'")
    machine.fail("su -s /bin/sh sender -c 'curl --max-time 2 http://172.31.255.2:8000/status'")
    # Run as the application's actual container uid, with the production mounts,
    # runtime and network. The host marker and Docker socket are outside its view.
    machine.succeed("echo synthetic-host-secret > /run/host-secret")
    probe = """
import os, socket
from pathlib import Path
assert os.getuid() == 64110
for path in ['/run/host-secret', '/run/docker.sock', '/run/credentials/device-token', '/persist']:
    assert not Path(path).exists(), path
try:
    Path('/etc/application-write').write_text('unexpected')
except OSError:
    pass
else:
    raise AssertionError('root filesystem is writable')
for host, port in [('172.31.255.1',22),('192.168.1.2',443),('100.64.0.1',80),('1.1.1.1',443)]:
    try:
        socket.create_connection((host,port),timeout=1).close()
    except OSError:
        continue
    raise AssertionError((host,port))
"""
    machine.succeed(f"docker exec site-apprise {python} -c {shlex.quote(probe)}")
    containers = json.loads(machine.succeed("docker inspect site-apprise site-bark"))
    assert all(container["HostConfig"]["Runtime"] == "runsc" for container in containers), containers
    machine.succeed("docker inspect site-apprise site-bark > /tmp/notification-containers.json")
    machine.succeed("docker stats --no-stream --format '{{json .}}' site-apprise site-bark > /tmp/notification-memory.jsonl")
    machine.copy_from_machine("/tmp/notification-memory.jsonl")
    machine.copy_from_machine("/tmp/notification-containers.json")
