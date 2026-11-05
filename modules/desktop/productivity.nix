{
  config,
  lib,
  pkgs,
  ...
}:
let
  safeeyesHardening = import ../../lib/desktop-service-hardening.nix {
    persistRoot = config.site.storage.persistRoot;
    stateDirectory = ".config/safeeyes";
  };
in
{
  options.site.productivity.enable = lib.mkEnableOption "desktop productivity applications";
  config = lib.mkMerge [
    (lib.mkIf config.site.productivity.enable {
      programs.firejail.enable = true;
      nixpkgs.config.allowUnfreePackages = [
        "anytype"
        "anytype-heart"
      ];
      environment.systemPackages = with pkgs; [
        blender
        libreoffice
      ];
      services.safeeyes.enable = true;
    })
    (lib.mkIf config.services.safeeyes.enable {
      environment.systemPackages = [
        (import ../../nix/safeeyes.nix {
          inherit pkgs;
          hardening = safeeyesHardening;
        })
      ];
      systemd.user.services.safeeyes = {
        wantedBy = lib.mkForce [ "xdg-desktop-autostart.target" ];
        after = [ "graphical-session.target" ];
      };
      systemd.user.services.safeeyes.serviceConfig = safeeyesHardening // {
        ExecStartPre = "${pkgs.glib}/bin/gdbus wait --session --timeout 30 org.kde.StatusNotifierWatcher";
        RuntimeDirectory = "safeeyes";
        RuntimeDirectoryMode = "0700";
        # Generated icons and autostart entries belong to this service's
        # runtime home; preferences remain in the persistent config bind.
        Environment = [
          "HOME=%t/safeeyes"
          "TMPDIR=%t/safeeyes"
          "XDG_CONFIG_HOME=%h/.config"
          "XDG_CACHE_HOME=%t/safeeyes/cache"
          "XDG_DATA_HOME=%t/safeeyes/data"
          "GSK_RENDERER=cairo"
        ];
      };
    })
  ];
}
