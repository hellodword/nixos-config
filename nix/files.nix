{ pkgs }:
let
  root = pkgs.runCommand "httpserver-root" { } ''
    mkdir -p $out/share $out/single $out/socket $out/tmp $out/etc/nginx
    ln -s ${pkgs.nginx}/conf/mime.types $out/etc/nginx/mime.types
    chmod 1777 $out/tmp
  '';
  entrypoint = pkgs.writeShellScriptBin "httpserver-entry" ''
    set -euo pipefail
    ${pkgs.dufs}/bin/dufs "$@" >/dev/null &
    dufs_pid=$!
    nginx_pid=
    cleanup() {
      kill -TERM "$dufs_pid" ''${nginx_pid:+"$nginx_pid"} 2>/dev/null || true
      wait "$dufs_pid" ''${nginx_pid:+"$nginx_pid"} 2>/dev/null || true
    }
    trap cleanup EXIT INT TERM HUP
    for ((i = 0; i < 150; i++)); do
      if [[ -S /tmp/dufs.sock ]]; then
        break
      fi
      kill -0 "$dufs_pid" 2>/dev/null
      ${pkgs.coreutils}/bin/sleep 0.02
    done
    [[ -S /tmp/dufs.sock ]]
    ${pkgs.nginx}/bin/nginx -e stderr -c /etc/nginx/nginx.conf -g 'daemon off;' &
    nginx_pid=$!
    wait -n "$dufs_pid" "$nginx_pid" || true
    exit 1
  '';
  image = pkgs.dockerTools.buildLayeredImage {
    name = "site-httpserver";
    contents = [
      root
      entrypoint
    ];
    config = {
      Entrypoint = [
        "${pkgs.tini}/bin/tini"
        "-g"
        "--"
        "${entrypoint}/bin/httpserver-entry"
      ];
      Labels."org.nixos-config.service" = "site-httpserver";
    };
  };
in
{
  inherit image;
  httpserver =
    settings:
    pkgs.writeShellApplication {
      name = "httpserver";
      runtimeInputs = [
        pkgs.python3
        pkgs.docker
        pkgs.file
        pkgs.iproute2
        pkgs.openssl
        pkgs.qrencode
      ];
      text = ''
        exec python3 ${../scripts/files/httpserver.py} \
          ${
            pkgs.writeText "httpserver.json" (
              builtins.toJSON (
                settings
                // {
                  image = "${image.imageName}:${image.imageTag}";
                  imageFile = toString image;
                  loginPage = "${../scripts/files/share-login.html}";
                }
              )
            )
          } "$@"
      '';
    };
  client = pkgs.writeShellApplication {
    name = "site-files-client";
    runtimeInputs = [
      pkgs.python3
      pkgs.openssl
      pkgs.systemd
    ];
    text = ''
      exec python3 ${../scripts/files/client.py} "$@"
    '';
  };
  certificate =
    configFile:
    pkgs.writeShellApplication {
      name = "site-files-certificate";
      runtimeInputs = [
        pkgs.openssl
        pkgs.coreutils
        pkgs.util-linux
        pkgs.systemd
        (pkgs.python3.withPackages (p: [ p.pyyaml ]))
      ];
      text = ''
        exec ${pkgs.bash}/bin/bash ${../scripts/files/certificate.sh} ${pkgs.lib.escapeShellArg configFile} "$@"
      '';
    };
}
