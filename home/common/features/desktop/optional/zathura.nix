{
  pkgs,
  config,
  persistPath,
  nixosConfig,
  ...
}:

let
  mkJailed = import ../../../../../modules/common/jailed.nix pkgs;
in
{
  programs.zathura = {
    enable = true;
    package =
      if nixosConfig.programs.firejail.enable then
        (mkJailed {
          originalPkg = pkgs.zathura;
          profile = "${pkgs.firejail}/etc/firejail/zathura.profile";
        })
      else
        pkgs.zathura;
  };

  me.mimeApps.defApps.reader = "org.pwmt.zathura.desktop";

  home.packages = [
    # pdftotext
    pkgs.poppler_utils
  ];

  home = {
    persistence = {
      "${persistPath}${config.home.homeDirectory}".directories = [
        ".local/share/zathura"
      ];
    };
  };
}
