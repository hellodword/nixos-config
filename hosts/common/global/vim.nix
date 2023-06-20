{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    vim
  ];

  environment.variables = {
    "EDITOR" = "${pkgs.vim}/bin/vim";
  };
}
