{ lib, inputs, pkgs, config, persistPath, ... }:

{
  # TODO backup
  home = {
    sessionVariables.BROWSER = "firefox";
    persistence = {
      "${persistPath}${config.home.homeDirectory}".directories = [ ".mozilla/firefox" ];
    };
  };

  xdg.mimeApps.defaultApplications = {
    "text/html" = [ "firefox.desktop" ];
    "text/xml" = [ "firefox.desktop" ];
    "x-scheme-handler/http" = [ "firefox.desktop" ];
    "x-scheme-handler/https" = [ "firefox.desktop" ];
  };

  # TODO config
  # https://gist.github.com/0XDE57/fbd302cef7693e62c769
  # https://github.com/arkenfox/user.js/
  programs.firefox = {
    enable = true;
    package = pkgs.firefox;
    profiles = {
      default = {
        id = 0;
        isDefault = true;
        userChrome = "";
        userContent = "";
        settings = {
          "browser.search.region" = "US";
          "browser.search.openintab" = true;
          "browser.search.defaultenginename" = "Google";
          "browser.search.selectedEngine" = "Google";
          "browser.urlbar.placeholderName" = "Google";

          "browser.download.panel.shown" = true;
          "browser.download.useDownloadDir" = false;

          "browser.shell.checkDefaultBrowser" = false;
          "browser.shell.defaultBrowserCheckCount" = 1;
        };
        bookmarks = [ ];
        # extensions = [ ];
        search = {
          default = "Google";
          force = true;
          order = [
            "Google"
            "Hacker News"
            "Github"
            "Github Actions"
            "Github Nix"
          ];
          engines = {
            "Github Actions" = {
              urls = [{
                template = "https://github.com/search?l=&p=1&q={searchTerms}+extension:yml+extension:yaml+path:.github/workflows&type=Code";
              }];
              definedAliases = [ "@actions" "actions" ];
            };
            "Github" = {
              urls = [{
                template = "https://github.com/search?q={searchTerms}";
              }];
              definedAliases = [ "@git" "git" ];
            };
            "Github Nix" = {
              urls = [{
                template = "https://github.com/search?q={searchTerms}+language%3Anix&type=code";
              }];
              definedAliases = [ "@gitnix" "gitnix" ];
            };
            "Hacker News" = {
              urls = [{
                template = "https://www.google.com/search?q=site%3Anews.ycombinator.com+{searchTerms}";
              }];
              definedAliases = [ "@hn" "hn" ];
            };
            "V2ex" = {
              urls = [{
                template = "https://www.google.com/search?q={searchTerms}+site:v2ex.com";
              }];
              definedAliases = [ "@v2ex" "v2ex" ];
            };

            # "Bing".metaData.hidden = true;
            "Google".metaData.alias = "@g"; # builtin engines only support specifying one additional alias
          };
        };
        # https://github.com/Baitinq/nixos-config/blob/1ab479c29c7dc2629664ffb80653616666019b9e/hosts/home.nix#L200
        extraConfig = lib.strings.concatStrings [
          (builtins.readFile "${inputs.arkenfox-userjs}/user.js")
          ''
          ''
        ];
      };
    };
  };
}
