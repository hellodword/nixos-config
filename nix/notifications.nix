{
  pkgs,
  caBundle,
}:
let
  py = pkgs.python3Packages;
  apprise = py.apprise.overridePythonAttrs (old: {
    version = "2.1.0";
    src = pkgs.fetchFromGitHub {
      owner = "caronc";
      repo = "apprise";
      tag = "v2.1.0";
      hash = "sha256-JgPYySIOyIq/l7ysT/yy69HIdxhdhJMBBTG7Jg4k7uw=";
    };
    dependencies = old.dependencies ++ [
      py.urllib3
      py.certifi
    ];
  });
  api = py.buildPythonPackage {
    pname = "apprise-api";
    version = "2.0.2";
    src = pkgs.fetchFromGitHub {
      owner = "caronc";
      repo = "apprise-api";
      tag = "v2.0.2";
      hash = "sha256-aRU+Mhoz2fftydl8UhvaBdZ/qhEIs7Pia4hKE1Hx3qQ=";
    };
    pyproject = true;
    build-system = [ py.setuptools ];
    dependencies = [
      apprise
      py.django
      py.gevent
      py.gunicorn
      py.requests
      py.paho-mqtt
      py.gntp
      py.cryptography
      py.django-prometheus
      py.pgpy
      py.smpplib
      py.slixmpp
      py.pika
    ];
    # Upstream starts this Django tree with core/api as top-level packages.
    postInstall = ''
      cp -r apprise_api/static "$out/${pkgs.python3.sitePackages}/apprise_api/"
      cp -r apprise_api/api/templates "$out/${pkgs.python3.sitePackages}/apprise_api/api/"
    '';
    pythonImportsCheck = [ "apprise_api" ];
    meta.license = pkgs.lib.licenses.mit;
  };
  python = pkgs.python3.withPackages (_: [
    api
    py.pyyaml
  ]);
  apiRoot = "${api}/${pkgs.python3.sitePackages}/apprise_api";
  bootstrap = pkgs.writeShellScript "apprise-api-start" ''
    export PYTHONPATH=${apiRoot}
    exec ${python}/bin/python3 ${../scripts/notifications/bootstrap.py} ${python}/bin/gunicorn ${apiRoot}
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
    pkgs.dockerTools.streamLayeredImage {
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
    api
    apprise
    python
    apiRoot
    ;
  apiImage = image "site-apprise" 64110 bootstrap [
    "PYTHONDONTWRITEBYTECODE=1"
    "DJANGO_SETTINGS_MODULE=core.settings"
    "APPRISE_CONFIG_DIR=/tmp/config"
    "APPRISE_STORAGE_DIR=/tmp/store"
    "APPRISE_ATTACH_DIR=/tmp/attachments"
    "APPRISE_PLUGIN_PATHS=/var/empty"
    "APPRISE_STATEFUL_MODE=simple"
    "APPRISE_STATELESS_MODE=disabled"
    "APPRISE_CONFIG_LOCK=yes"
    "APPRISE_AUTH_REQUIRED=yes"
    "APPRISE_ADMIN=no"
    "APPRISE_API_ONLY=yes"
    "APPRISE_ALLOW_SERVICES=bark,wecombot,wechat,dingtalk,feishu"
    "APPRISE_ATTACH_SIZE=0"
    "APPRISE_ATTACH_ALLOW_URL="
    "APPRISE_HTTP_REDIRECTS=no"
    "APPRISE_ALLOW_TEMPLATES=yes"
    "LOG_LEVEL=WARNING"
    "ALLOWED_HOSTS=localhost"
    "REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt"
  ];
  barkImage = image "site-bark" 64111 barkStart [ ];
}
