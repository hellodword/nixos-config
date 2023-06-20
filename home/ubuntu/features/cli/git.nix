{ pkgs, ... }:

{
  programs.git = {
    enable = true;
    package = pkgs.git;
    extraConfig = {
      core.editor = "vim";
    };
  };
}
