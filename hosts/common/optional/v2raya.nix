{ lib, config, pkgs, persistPath, ... }:
let
  iptablesCmd = "${pkgs.iptables}/bin/iptables";
  modprobeCmd = "${pkgs.kmod}/bin/modprobe";
  v2raya-tproxy-enable-docker = pkgs.writeShellApplication {
    name = "v2raya-tproxy-enable-docker";
    runtimeInputs = with pkgs; [ wget coreutils ];
    text = ''
      #!/bin/bash


      # parse the arguments
      for i in "$@"; do
        case $i in
          --transparent-type=*)
            TYPE="''${i#*=}"
            shift
            ;;
          --stage=*)
            STAGE="''${i#*=}"
            shift
            ;;
          -*)
            echo "Unknown option $i"
            shift
            ;;
          *)
            ;;
        esac
      done

      set -x

      case "$STAGE" in
      post-start)
        # at the post-start stage
        if [ "$TYPE" = "tproxy" ]; then
          # we check if the transparent type is tproxy, and if so, we disable the bridge netfilter call and remove the docker rule in the TP_RULE chain.
          ${modprobeCmd} br_netfilter
          # sysctl net.bridge.bridge-nf-call-ip6tables=0
          # sysctl net.bridge.bridge-nf-call-iptables=0
          # sysctl net.bridge.bridge-nf-call-arptables=0
          ${iptablesCmd} -t mangle -D TP_RULE -i br-+ -j RETURN || true
          ${iptablesCmd} -t mangle -D TP_RULE -i docker+ -j RETURN || true
        fi
        ;;
      *)
        ;;
      esac

      exit 0
    '';
  };
in
{
  environment.variables.V2RAYA_ADDRESS = "http://127.0.0.1:2017";
  services.v2raya.enable = true;

  environment.persistence = {
    "${persistPath}".directories = [
      "/etc/v2raya"
    ];
  };

  # after docker iptables
  systemd.services."v2raya".unitConfig.After = lib.optionals config.virtualisation.docker.enable [ "docker.service" ];

  systemd.services."v2raya".serviceConfig =
    {
      ExecStart = lib.mkForce "${pkgs.v2raya}/bin/v2rayA --log-disable-timestamp --transparent-hook ${v2raya-tproxy-enable-docker}/bin/v2raya-tproxy-enable-docker";
    };

  # Options for routing
  boot.kernel.sysctl = {
    # Disable netfilter for bridges, for performance and security
    # Note that this means bridge-routed frames do not go through iptables
    # https://bugzilla.redhat.com/show_bug.cgi?id=512206#c0

    # for tproxy and docker bridge network
    "net.bridge.bridge-nf-call-ip6tables" = "0";
    "net.bridge.bridge-nf-call-iptables" = "0";
    "net.bridge.bridge-nf-call-arptables" = "0";
  };
}
