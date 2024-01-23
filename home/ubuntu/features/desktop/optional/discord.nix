{ config, pkgs, persistPath, ... }:

let
  mkJailed = import ../../../../../modules/common/jailed.nix pkgs;
in
{
  # https://github.com/Discord-Client-Encyclopedia-Management/Discord3rdparties#third-party-reimplementations

  # # official
  # home.packages = with pkgs; [
  #   (
  #     if nixosConfig.programs.firejail.enable then
  #       (mkJailed {
  #         originalPkg = pkgs.discord;
  #         profile = "${pkgs.firejail}/etc/firejail/discord.profile";
  #       })
  #     else
  #       pkgs.discord
  #   )
  # ];

  # me.allowedUnfreePkg = [
  #   "discord"
  # ];

  # home.persistence = {
  #   "${persistPath}${config.home.homeDirectory}".directories = [ ".config/discord" ];
  # };
}
