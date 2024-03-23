{ config, pkgs, persistPath, ... }:

{
  home.persistence = {
    "${persistPath}${config.home.homeDirectory}".directories = [ ".cache/thunderbird" ];
  };

  # TODO backup
  # TODO config
  programs.thunderbird = {
    enable = true;
    package = pkgs.thunderbird;
    settings = {
      # "general.useragent.override" = "";
      "privacy.donottrackheader.enabled" = true;
    };
    profiles = {
      default = {
        isDefault = true;
        withExternalGnupg = false;
        settings = {
          # "mail.spellcheck.inline" = false;
        };
        # userChrome = "";
        # userContent = "";
        # https://github.com/Baitinq/nixos-config/blob/1ab479c29c7dc2629664ffb80653616666019b9e/hosts/home.nix#L200
        # extraConfig = lib.strings.concatStrings [
        #   (builtins.readFile "${inputs.thunderbird-userjs}/user.js")
        #   ''
        #   ''
        # ];
      };
    };
  };
}
