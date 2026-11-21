{
  pkgs,
  caBundle,
}:
let
  py = pkgs.python3Packages;
  apprise = py.apprise;
  python = pkgs.python3.withPackages (_: [
    apprise
    py.pyyaml
  ]);
  bootstrap = pkgs.writeShellScript "apprise-start" ''
    exec ${python}/bin/python3 ${../scripts/notifications/bootstrap.py}
  '';
  barkStart = pkgs.writeShellScript "bark-start" ''
    export BARK_KEY=local
    BARK_DEVICE_TOKEN=$(< /run/credentials/device-token)
    export BARK_DEVICE_TOKEN
    exec ${pkgs.bark-server}/bin/bark-server --serverless --addr 0.0.0.0:8080 \
      --concurrency 16 --read-timeout 5s --write-timeout 20s --max-batch-push-count 1
  '';
  roots = pkgs.runCommand "notification-trust" { } ''
    mkdir -p $out/etc/ssl/certs $out/tmp $out/run/credentials $out/var/empty
    cp ${caBundle} $out/etc/ssl/certs/ca-certificates.crt
    chmod 1777 $out/tmp
  '';
  image =
    name: uid: command: env:
    pkgs.dockerTools.buildLayeredImage {
      inherit name;
      tag = "local";
      contents = [ roots ];
      config = {
        User = "${toString uid}:${toString uid}";
        Cmd = [ command ];
        Env = [
          "HOME=/tmp"
          "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"
        ]
        ++ env;
        WorkingDir = "/tmp";
      };
    };
in
{
  inherit
    apprise
    python
    ;
  apiImage = image "site-apprise" 64110 bootstrap [
    "PYTHONDONTWRITEBYTECODE=1"
    "REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt"
  ];
  barkImage = image "site-bark" 64111 barkStart [ ];
}
