{ pkgs, lib, persistPath, ... }:

let
  sbBase = "/var/lib/sing-box";
  sbBaseReal = "/var/lib/private/sing-box";
  sbTemplateFile = "template.json";
  sbConfigFile = "sing-box.json";
  sbBypassUserGenerate = pkgs.writeShellApplication {
    name = "exe";
    runtimeInputs = with pkgs; [ jq ];
    excludeShellChecks = [ "SC2086" ];
    text = ''
      set -x
      cd /var/lib/sing-box
      rm -rf ${sbConfigFile}

      uids=()

      mosdns="$(id -u mosdns || true)"
      if [ -n "$mosdns" ]; then
        uids+=("$mosdns")
      fi

      tailscaled="$(id -u tailscaled || true)"
      if [ -n "$tailscaled" ]; then
        uids+=("$tailscaled")
      fi

      IFS=','
      _uids="''${uids[*]}"

      jq "(.inbounds[] | select(.type == \"tun\")).exclude_uid = [$_uids]" ${sbTemplateFile} > ${sbConfigFile}
    '';
  };
in
{
  environment.systemPackages = with pkgs; [
    sing-box
  ];

  networking.firewall.enable = lib.mkForce false;

  # https://github.com/A1ca7raz/flamework/blob/main/modules/services/client/sing-box/default.nix#L78-L105
  systemd.services.sing-box = {
    enable = true;
    description = "Sing-box networking service";
    wantedBy = [ "multi-user.target" ];
    requires = [ "network-online.target" ];
    after = [ "network-online.target" ];
    path = with pkgs; [ curl sing-box ];

    serviceConfig = {
      Type = "simple";

      ExecStartPre = [
        "+${sbBypassUserGenerate}/bin/exe"
      ];
      ExecStart = "${pkgs.sing-box}/bin/sing-box run -D ${sbBase} -c ${sbBase}/${sbConfigFile}";

      # Sing-box Auto Update
      Restart = "on-failure";
      RestartPreventExitStatus = 23;

      # # OOM Killer
      # OOMPolicy = "kill";
      # MemoryMax = "200M";

      DynamicUser = "yes";
      LogDirectory = "sing-box";
      RuntimeDirectory = "sing-box";
      StateDirectory = "sing-box";
      # Capabilities
      CapabilityBoundingSet = "CAP_NET_ADMIN CAP_NET_BIND_SERVICE";
      AmbientCapabilities = "CAP_NET_ADMIN CAP_NET_BIND_SERVICE";
      # # Proc filesystem
      # ProcSubset = "pid";
      # ProtectProc = "invisible";
      # Security
      NoNewPrivileges = true;
      # Sandboxing
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      # PrivateDevices = true; # NOT WORK on Tun Mode
      # DeviceAllow = "/dev/net/tun rw";
      PrivateMounts = true;
      PrivateTmp = true;
      # PrivateUsers = true;          # NOT WORK on Tun Mode
      ProtectClock = true;
      ProtectControlGroups = true;
      ProtectHome = true;
      ProtectHostname = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectSystem = "strict";
      RemoveIPC = true;
      RestrictAddressFamilies = "AF_INET AF_INET6 AF_NETLINK";
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      # System Call Filtering
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "~@cpu-emulation @debug @keyring @mount @obsolete @privileged @setuid" "setrlimit" ];
    };
  };

  environment.persistence = {
    "${persistPath}".directories = [
      sbBaseReal
    ];
  };
}
