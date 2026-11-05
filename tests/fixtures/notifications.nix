{ pkgs }:
let
  # Public test material generated in the build sandbox, never used on a real host.
  certs =
    pkgs.runCommand "notification-fixture-certificate" { nativeBuildInputs = [ pkgs.openssl ]; }
      ''
        mkdir $out
        openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
          -subj '/CN=Notification test CA' \
          -addext 'basicConstraints=critical,CA:TRUE' \
          -addext 'subjectAltName=DNS:api.push.apple.com,DNS:qyapi.weixin.qq.com,DNS:oapi.dingtalk.com,DNS:open.feishu.cn' \
          -keyout $out/key.pem -out $out/cert.pem 2>/dev/null
      '';
  python = pkgs.python3.withPackages (p: [ p.h2 ]);
in
rec {
  command = "${python}/bin/python3 ${./notification_server.py} --cert ${certs}/cert.pem --key ${certs}/key.pem";
  ca = "${certs}/cert.pem";
  server = { lib, ... }: {
    systemd.services.notification-fixture = {
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig.ExecStart = lib.mkDefault command;
    };
  };
  credentials = { ... }: {
    site.notifications = {
      enable = true;
      users = [ "sender" ];
      barkDeviceTokenFile = "/run/notification-fixture-token";
      extraConfigFile = "/run/notification-fixture-channels";
    };
    users.users.sender = {
      isNormalUser = true;
    };
    systemd.services.site-notification-secrets.preStart = ''
      printf '%s' synthetic-apns-token > /run/notification-fixture-token
      printf '%s\n' 'urls:' '  - wecombot://synthetic-webhook-token:' '    - tag: wecom' > /run/notification-fixture-channels
      chmod 600 /run/notification-fixture-token /run/notification-fixture-channels
    '';
  };
}
