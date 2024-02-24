{ config, lib, pkgs, persistPath, ... }:

let
  sbBypassUserDel = pkgs.writeShellApplication {
    name = "exe";
    runtimeInputs = with pkgs; [ iproute2 findutils gnugrep bash ];
    excludeShellChecks = [ "SC2086" ];
    text = ''
      set -x

      _USER_NAME="$1"
      [ -n "$_USER_NAME" ]

      _USER_ID="$(id -u "$_USER_NAME" || true)"
      if [ -n "$_USER_ID" ]; then
          ip -4 rule list | grep -oP "(?<=\d:\t)from all uidrange $_USER_ID-$_USER_ID goto \d+" | xargs -I {} bash -xc 'ip -4 rule del {}' || true
          ip -6 rule list | grep -oP "(?<=\d:\t)from all uidrange $_USER_ID-$_USER_ID goto \d+" | xargs -I {} bash -xc 'ip -6 rule del {}' || true
      fi
    '';
  };
  sbBypassUserAdd = pkgs.writeShellApplication {
    name = "exe";
    runtimeInputs = with pkgs; [ iproute2 gnugrep ];
    excludeShellChecks = [ "SC2086" ];
    text = ''
      set -x

      _USER_NAME="$1"
      [ -n "$_USER_NAME" ]

      _IPV4_ID="$(ip -4 rule list | grep -oP '^\d+(?=:\tfrom all nop$)' || true)"
      _IPV6_ID="$(ip -6 rule list | grep -oP '^\d+(?=:\tfrom all nop$)' || true)"
      _USER_ID="$(id -u "$_USER_NAME" || true)"
      if [ -n "$_USER_ID" ]; then
          if [ -n "$_IPV4_ID" ]; then
              ip -4 rule add from all uidrange $_USER_ID-$_USER_ID goto "$_IPV4_ID"
          fi
          if [ -n "$_IPV6_ID" ]; then
              ip -6 rule add from all uidrange $_USER_ID-$_USER_ID goto "$_IPV6_ID"
          fi
      fi
    '';
  };
in
{
  environment.systemPackages = [
    pkgs.tailscale
  ];

  services.tailscale = {
    enable = true;
    package = pkgs.tailscale;
    authKeyFile = config.sops.secrets."tailscale-auth-key".path;
    extraUpFlags = [
      # https://tailscale.com/kb/1072/client-preferences#in-the-cli
      # block incoming connections
      "--shields-up"
    ];
    interfaceName = "tailscale";
    openFirewall = false;
    # permitCertUid = null;
    port = 41641;
    useRoutingFeatures = "client";
  };

  sops.secrets."tailscale-auth-key" = {
    sopsFile = ../../${config.networking.hostName}/secrets/secrets.yaml;
  };

  systemd.services = lib.mergeAttrs
    ({
      tailscaled-autoconnect = {
        after = lib.mkForce [ "tailscaled.service" ];
        wants = lib.mkForce [ "tailscaled.service" ];
        serviceConfig = {
          AmbientCapabilities = [
            "CAP_NET_ADMIN"
            # TODO minify
            # "CAP_SYS_ADMIN"
          ];
          # DynamicUser = true;
        };
      };

      tailscaled = {
        serviceConfig = {
          AmbientCapabilities = [ "CAP_NET_ADMIN" ];
          DynamicUser = true;
          # 直连
          ExecStartPre = lib.optionals (builtins.hasAttr "sing-box" config.systemd.services) [
            "+${sbBypassUserDel}/bin/exe tailscaled"
            "+${sbBypassUserAdd}/bin/exe tailscaled"
          ];
          ExecStop = lib.optionals (builtins.hasAttr "sing-box" config.systemd.services) [
            "+${sbBypassUserDel}/bin/exe tailscaled"
          ];
        };
      };
    })
    (
      # avoid infinite recursion
      lib.optionalAttrs
        (builtins.length (builtins.filter (x: builtins.typeOf x == "set" && lib.hasAttr "directory" x && x.directory == "/var/lib/private/sing-box") config.environment.persistence."${persistPath}".directories) == 1)
        {
          sing-box =
            {
              serviceConfig = {
                ExecStartPre = lib.mkBefore [
                  "+${sbBypassUserDel}/bin/exe tailscaled"
                ];
                ExecStop = lib.mkBefore [
                  "+${sbBypassUserDel}/bin/exe tailscaled"
                ];
              };
            };
        }
    );



  environment.persistence = {
    "${persistPath}".directories = [
      # https://www.reddit.com/r/NixOS/comments/14w1404/every_nixos_rebuild_creates_a_new_tailscale/
      "/var/lib/private/tailscale"
    ];
  };
}
