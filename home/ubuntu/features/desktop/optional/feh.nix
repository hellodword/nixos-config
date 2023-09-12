{ pkgs, nixosConfig, ... }:

{
  programs.feh = {
    enable = true;
    package =
      if nixosConfig.programs.firejail.enable then
        (builtins.elemAt
          (builtins.filter (x: x.meta.name == "firejail-wrapped-binaries") nixosConfig.environment.systemPackages)
          0)
      else
        pkgs.feh;
    buttons = { };
    keybindings = {
      quit = [ "C-q" "C-w" ];
    };
  };

  me.mimeApps.defApps.imageViewer = "feh.desktop";
}
