{ pkgs, ... }:

{
  programs.git = {
    enable = true;
    package = pkgs.gitAndTools.gitFull;
    extraConfig = {
      core.editor = "vim";
    };
    aliases = {
      "config-github" = "!git config user.name hellodword && git config user.email 46193371+hellodword@users.noreply.github.com";
      "config-dependabot" = "!git config user.name dependabot[bot] && git config user.email 49699333+dependabot[bot]@users.noreply.github.com";
      "remote-add-github" = "!f() { git remote add origin git@hellodword.github.com:hellodword/$1.git; }; f";
    };
  };
}
