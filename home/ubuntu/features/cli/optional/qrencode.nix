{ pkgs, nixosConfig, ... }:

{
  home.packages = [
    (
      if nixosConfig.programs.firejail.enable then
        (builtins.elemAt
          (builtins.filter (x: x.meta.name == "firejail-wrapped-binaries") nixosConfig.environment.systemPackages)
          0)
      else
        pkgs.qrencode
    )
  ];

  programs.bash.shellAliases = {
    "qr" = "qrencode -t ANSI256UTF8";
  };
}
