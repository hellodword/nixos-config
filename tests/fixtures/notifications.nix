{ pkgs }:
let
  # Fixed public test material keeps the server and cached container trust
  # bundles identical. Validity covers the fixture's clock changes (2020–2040).
  python = pkgs.python3.withPackages (p: [ p.h2 ]);
in
rec {
  command = "${python}/bin/python3 ${./notification_server.py} --cert ${ca} --key ${./notification-tls/key.pem}";
  ca = "${./notification-tls/cert.pem}";
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
