{
  config,
  lib,
  pkgs,
  inputs,
  nixosConfig,
  ...
}:
let
  browser = builtins.fromJSON (builtins.readFile ../data/firefox.json);
  code = builtins.fromJSON (builtins.readFile ../data/vscode.json);
  prefs = {
    "keyword.enabled" = true;
    "browser.search.suggest.enabled" = false;
    "dom.allow_cut_copy" = true;
    "privacy.resistFingerprinting.letterboxing" = false;
    "browser.uidensity" = 0;
    "media.gmp-widevinecdm.enabled" = true;
    "media.eme.enabled" = true;
    "webgl.disabled" = false;
    "network.http.referer.XOriginTrimmingPolicy" = 0;
    "browser.startup.page" = 3;
    "browser.sessionstore.max_tabs_undo" = 27;
    "browser.sessionstore.privacy_level" = 0;
    "browser.sessionstore.interval" = 15000;
    "general.autoScroll" = true;
    "network.cookie.cookieBehavior" = 5;
    "privacy.sanitize.sanitizeOnShutdown" = false;
    "browser.urlbar.suggest.topsites" = false;
    "browser.toolbars.bookmarks.visibility" = "newtab";
    "network.dns.disableIPv6" = false;
    "network.trr.mode" = 5;
    "doh-rollout.disable-heuristics" = true;
    "extensions.formautofill.addresses.enabled" = false;
    "extensions.formautofill.creditCards.enabled" = false;
    "browser.formfill.enable" = false;
    "signon.rememberSignons" = true;
    "signon.autofillForms" = true;
    "signon.management.page.breach-alerts.enabled" = false;
    "signon.firefoxRelay.feature" = "disabled";
    "signon.generation.enabled" = false;
    "extensions.update.autoUpdateDefault" = false;
  };

  addon = inputs.reproducible-violentmonkey.lib.violentmonkeyBuildFirefoxXpiAddonArgs;
  xpi = pkgs.fetchurl { inherit (addon) url sha256; };
  violentmonkey = pkgs.runCommand "violentmonkey-${addon.version}" { } ''
    install -Dm444 ${xpi} "$out/share/mozilla/extensions/{ec8030f7-c20a-464f-9b0e-13a3a9e97384}/${addon.addonId}.xpi"
  '';
  arkenfox = lib.concatStringsSep "\n" (
    builtins.filter (
      line: builtins.match ''[[:space:]]*user_pref\("privacy\.clearOnShutdown.*'' line == null
    ) (lib.splitString "\n" (builtins.readFile (inputs.arkenfox-userjs + /user.js)))
  );
in
{
  imports = [ ./sandbox.nix ];
  config = lib.mkIf nixosConfig.site.apps.enable {
    home.sessionVariables.BROWSER = "firefox";
    programs.firefox = {
      enable = true;
      configPath = "${config.xdg.configHome}/mozilla/firefox";
      policies = {
        DisableTelemetry = true;
        DisableFirefoxStudies = true;
        DNSOverHTTPS = {
          Enabled = false;
          Locked = true;
        };
      };
      profiles = {
        default = {
          id = 0;
          isDefault = true;
          preConfig = arkenfox;
          settings = prefs;
          search = browser.search // {
            force = true;
          };
          bookmarks = {
            force = true;
            settings = browser.bookmarks;
          };
          extensions.packages = [ violentmonkey ];
        };
        origin = {
          id = 1;
          isDefault = false;
        };
      };
    };
    programs.vscode = {
      enable = true;
      argvSettings = {
        password-store = "gnome-libsecret";
        enable-crash-reporter = false;
      };
      mutableExtensionsDir = true;
      profiles.default = {
        extensions = with pkgs.vscode-extensions; [
          jnoortheen.nix-ide
          ms-vscode-remote.remote-containers
        ];
        userSettings = code.userSettings;
        keybindings = code.keybindings;
      };
    };
    programs.mpv = {
      enable = true;
      config = {
        hwdec = "auto-safe";
        keep-open = true;
        screenshot-directory = config.xdg.userDirs.pictures;
      };
    };
    xdg.mimeApps = {
      enable = true;
      defaultApplications = {
        "text/html" = [ "firefox.desktop" ];
        "x-scheme-handler/http" = [ "firefox.desktop" ];
        "x-scheme-handler/https" = [ "firefox.desktop" ];
        "text/plain" = [ "code.desktop" ];
        "video/mp4" = [ "mpv.desktop" ];
        "image/png" = [ "feh.desktop" ];
        "image/jpeg" = [ "feh.desktop" ];
      };
    };
    home.packages = (
      with pkgs;
      [
        ffmpeg-full
        sqlite
        rclone
        kdePackages.kdeconnect-kde
      ]
    );
  };
}
