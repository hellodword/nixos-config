{ pkgs, ... }:

{
  home.packages = with pkgs; [
    qrencode
  ];

  programs.bash.shellAliases = {
    "qr" = "qrencode -t ANSI256UTF8";
  };
}
