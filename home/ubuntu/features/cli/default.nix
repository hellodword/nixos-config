{ pkgs, ... }:

{
  imports = [
    ./bash.nix
    ./git.nix
    ./ssh.nix
    ./gpg.nix
    ./screen.nix
  ];

  # systemd.user.services.autorandr.Unit.After = [ "sops-nix.service" ];
  services.autorandr.enable = true;
  /*
    systemd.user.services.autorandr = {
    Unit = {
      Description = "autorandr";
      After = [ "graphical-session-pre.target" ];
      PartOf = [ "graphical-session.target" ];
    };

    Service = {
      Type = "oneshot";
      ExecStart = "${pkgs.autorandr}/bin/autorandr --change";
    };

    Install.WantedBy = [ "graphical-session.target" ];
    };
  */

  home.packages = with pkgs; [
    jq # JSON pretty printer and manipulator

    nixpkgs-fmt
    nixpkgs-lint
    nil # Nix LSP
    nixfmt # Nix formatter
  ];
}
