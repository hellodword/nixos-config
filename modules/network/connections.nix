{
  config,
  lib,
  userName,
  ...
}:
let
  cfg = config.site.connections;
in
{
  options.site.connections.enable = lib.mkEnableOption "NetworkManager connections with persistent local profiles";
  config = lib.mkIf cfg.enable {
    networking.networkmanager = {
      enable = true;
      unmanaged = [
        "interface-name:wg0-mullvad"
        "interface-name:tailscale0"
        "interface-name:docker0"
        "interface-name:br-*"
        "interface-name:veth*"
        "interface-name:waydroid0"
      ];
    };
    users.users.${userName}.extraGroups = [ "networkmanager" ];
    programs.nm-applet.enable =
      config.services.xserver.enable
      && (config.programs.sway.enable || config.services.xserver.windowManager.i3.enable);
    systemd.user.services.nm-applet = lib.mkIf config.programs.nm-applet.enable {
      unitConfig.ConditionEnvironment = "!XDG_CURRENT_DESKTOP=KDE";
    };
    systemd.services.NetworkManager.unitConfig.RequiresMountsFor = [
      "/etc/NetworkManager/system-connections"
      "/var/lib/NetworkManager"
    ];
  };
}
