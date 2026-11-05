"""Exercise sending, provider failure and confinement together using the real services."""
import json
import shlex


def notification_smoke(machine, upstream, python):
    upstream.wait_for_unit("notification-fixture.service")
    machine.wait_for_unit("haproxy.service")
    machine.wait_for_unit("docker-site-apprise.service")
    machine.wait_for_unit("docker-site-bark.service")
    # Readiness is the first real delivery through the ordinary user's socket.
    machine.wait_until_succeeds("su -s /bin/sh sender -c 'bark 中文正文'", timeout=180)
    for arguments in ("'标题' '中文正文'", "'工作' '标题' '中文正文'", "'工作' '标题' '中文正文' 'glass'"):
        result = json.loads(machine.succeed("su -s /bin/sh sender -c " + shlex.quote("bark " + arguments)))
        assert result["channels"][0]["delivered"], result
    events = [json.loads(line) for line in upstream.succeed("cat /run/notification-fixture/events.jsonl").splitlines()]
    assert len(events) == 4, events
    payload = events[-1]["body"]["aps"]
    assert payload["alert"]["body"] == "中文正文", payload
    assert payload["alert"]["title"] == "标题", payload
    assert payload["thread-id"] == "工作" and payload["sound"] == "glass.caf", payload
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
