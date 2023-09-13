{ pkgs, nixosConfig, ... }:

let
  mkJailed = import ../../../../../modules/common/jailed.nix pkgs;
in
{
  home.packages = [
    (
      if nixosConfig.programs.firejail.enable then
        (mkJailed {
          originalPkg = pkgs.qrencode;
          profile = "${pkgs.firejail}/etc/firejail/qrencode.profile";
        })
      else
        pkgs.qrencode
    )
  ];

  programs.bash.shellAliases = {
    "qr" = "qrencode -t ANSI256UTF8";
  };
}
