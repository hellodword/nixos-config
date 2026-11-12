{ pkgs }:
let
  root = pkgs.runCommand "httpserver-root" { } ''
    mkdir -p $out/share $out/socket $out/tmp $out/etc/nginx
    ln -s ${pkgs.nginx}/conf/mime.types $out/etc/nginx/mime.types
    chmod 1777 $out/tmp
  '';
  image = pkgs.dockerTools.buildLayeredImage {
    name = "site-httpserver";
    contents = [ root ];
    config = {
      Cmd = [
        "${pkgs.nginx}/bin/nginx"
        "-e"
        "stderr"
        "-c"
        "/etc/nginx/nginx.conf"
        "-g"
        "daemon off;"
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
                }
              )
            )
          } "$@"
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
