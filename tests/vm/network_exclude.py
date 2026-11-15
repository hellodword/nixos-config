"""User commands, shared and private DNS, agent SSH and Docker on native egress."""
import shlex


def run(client, target):
    def user(command):
        return client.succeed("runuser -u desktop -- " +
                              "env HOME=/home/desktop SHELL=/run/current-system/sw/bin/bash " +
                              "bash -c " + shlex.quote(command))

    global_dns = "tls://dns.test.nix:24003"
    cn_dns = "tls://dns.test.nix:24001"
    query = "dig +time=3 +tries=1 +short web.proxy.test A"
    request = "curl -4 --noproxy '*' --max-time 8 -fsS http://web.proxy.test:18080/exclusion"
    client.wait_for_unit("site-network-exclude-dns.service")
    assert user("network-exclude " + query).strip() == "198.51.100.30"
    observed = user("network-exclude " + request).strip()
    assert observed == "192.168.1.10", observed
    observed = user("network-exclude " + request.replace("curl -4", "curl -6")).strip()
    assert observed == "2001:db8:10::10", observed
    assert user("network-exclude --dns " + cn_dns + " -- " + query).strip() == "192.0.2.30"
    shell_input = query + "; exit\n"
    assert "192.0.2.30" in user("printf %s " + shlex.quote(shell_input) +
                                " | network-exclude --dns " + cn_dns)

    client.succeed("docker run -d --name excluded --network site-direct network-workflow:test")
    client.succeed("docker run -d --name excluded-web --network site-direct network-workflow:test httpd -f -p 8080 -h /www")
    client.succeed("docker exec excluded curl -fsS http://excluded-web:8080 | grep -Fx 'container service'")
    assert client.succeed("docker exec excluded " + request).strip() == "192.168.1.10"
    assert client.succeed("docker run --rm --network site-direct --dns 192.168.1.20 "
                          "network-workflow:test " + query).strip() == "192.168.1.20"

    # Keep a temporary environment alive while changing the shared resolver.
    script = ("set -eu; " + query + " > /home/desktop/private-before; "
              "touch /home/desktop/private-ready; "
              "while ! test -e /home/desktop/private-go; do sleep 0.1; done; "
              "network-exclude " + query + " > /home/desktop/private-after")
    client.succeed("systemd-run --unit=exclude-private --property=User=desktop "
                   "--setenv=HOME=/home/desktop --setenv=PATH=/run/current-system/sw/bin "
                   "network-exclude --dns " + cn_dns + " -- bash -c " + shlex.quote(script))
    client.wait_until_succeeds("test -e /home/desktop/private-ready", timeout=30)
    user("network-exclude dns set " + cn_dns)
    assert client.succeed("docker exec excluded " + query).strip() == "192.0.2.30"
    assert user("network-exclude " + query).strip() == "192.0.2.30"
    user("network-exclude dns set " + global_dns)
    user("touch /home/desktop/private-go")
    client.wait_until_succeeds("test $(systemctl show exclude-private -p ActiveState --value) = inactive")
    assert user("cat ~/private-before ~/private-after").splitlines() == ["192.0.2.30"] * 2

    # The public key selects a signing identity in the caller's GPG agent.
    user("mkdir -p -m700 ~/.gnupg; printf 'enable-ssh-support\\n' > ~/.gnupg/gpg-agent.conf; "
         "gpg --batch --pinentry-mode loopback --passphrase '' --quick-generate-key "
         "'Network Fixture <exclude@example.invalid>' ed25519 auth 0")
    keys = user("gpg --batch --with-colons --with-keygrip --list-secret-keys")
    fingerprint = next(line.split(":")[9] for line in keys.splitlines() if line.startswith("fpr:"))
    grip = next(line.split(":")[9] for line in keys.splitlines() if line.startswith("grp:"))
    user("gpg-connect-agent 'KEYATTR " + grip + " Use-for-ssh: true' /bye")
    public = user("gpg --export-ssh-key " + fingerprint)
    client.succeed("printf %s " + shlex.quote(public) + " > /etc/ssh/gpg.exclusion.pub")
    target.succeed("mkdir -p -m700 /root/.ssh; printf %s " + shlex.quote(public) + " >> /root/.ssh/authorized_keys")
    ssh = ("export SSH_AUTH_SOCK=$(gpgconf --list-dirs agent-ssh-socket); "
           "network-exclude ssh -n -o BatchMode=yes -o LogLevel=ERROR -o StrictHostKeyChecking=accept-new "
           "-o IdentitiesOnly=yes -i /etc/ssh/gpg.exclusion.pub root@web.proxy.test 'printf agent-ok'")
    try:
        assert user(ssh).strip() == "agent-ok"
    finally:
        user("gpgconf --kill all")

    client.succeed("systemctl stop sing-box")
    try:
        assert user("network-exclude " + request).strip() == "192.168.1.10"
        assert client.succeed("docker exec excluded " + request).strip() == "192.168.1.10"
    finally:
        client.succeed("systemctl start sing-box")
    # Leave an override for the existing reboot scenario to observe resetting.
    user("network-exclude dns set " + cn_dns)
    client.succeed("docker rm -f excluded excluded-web")
