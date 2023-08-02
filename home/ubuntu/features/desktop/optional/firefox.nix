{ lib, inputs, pkgs, config, persistPath, ... }:

{
  # TODO backup
  home = {
    sessionVariables.BROWSER = "firefox";
    persistence = {
      "${persistPath}${config.home.homeDirectory}".directories = [ ".mozilla/firefox" ];
    };
  };

  me.mimeApps.defApps.webBrowser = "firefox.desktop";


  /*
    TODO ff sync self-hosted
        https://github.com/mozilla-services/syncstorage-rs/issues/1428
        https://github.com/mozilla-services/syncstorage-rs/issues/825
        https://hacks.mozilla.org/2018/11/firefox-sync-privacy/
  */
  programs.firefox = {
    enable = true;
    package = pkgs.firefox;
    profiles = {
      # for debug `firefox --profile ~/.mozilla/firefox/origin`
      origin = {
        id = 1;
        isDefault = false;
      };
      default = {
        id = 0;
        isDefault = true;
        # userChrome = "";
        # userContent = "";
        bookmarks = [
          {
            name = "Chat";
            toolbar = true;
            bookmarks = [
              {
                name = "Element";
                url = "https://app.element.io/";
              }
              {
                name = "Discord";
                url = "https://discord.com/channels/@me";
              }
            ];
          }
          {
            name = "Forum";
            toolbar = true;
            bookmarks = [
              {
                name = "V2EX";
                url = "https://www.v2ex.com/";
              }
            ];
          }
          {
            name = "Tools";
            toolbar = true;
            bookmarks = [
              {
                name = "CyberChef";
                url = "https://gchq.github.io/CyberChef/";
              }
            ];
          }
          {
            name = "Nix / NixOS";
            toolbar = true;
            bookmarks = [
              {
                name = "NixOS Manual options";
                url = "https://nixos.org/manual/nixos/unstable/options.html";
              }
              {
                name = "home-manager options";
                url = "https://nix-community.github.io/home-manager/options.html";
              }
              {
                name = "Nixpkgs Pull Request Tracker";
                url = "https://nixpk.gs/pr-tracker.html";
              }
              {
                name = "Nixpkgs";
                url = "https://github.com/NixOS/nixpkgs";
              }
              {
                name = "home-manager";
                url = "https://github.com/nix-community/home-manager";
              }
            ];
          }
        ];
        extensions = [
          (inputs.firefox-addons.lib.${pkgs.system}.buildFirefoxXpiAddon {
            pname = "tampermonkey";
            addonId = "firefox@tampermonkey.net";
            version = "4.19.0";
            url =
              "https://addons.mozilla.org/firefox/downloads/file/4115771/tampermonkey-4.19.0.xpi";
            sha256 = "0f6v853mccj2rkmjy3g9r1gvgk7yfad7mjh1wqzdhhws7imiysi2";
            meta = { };
          })
          (inputs.firefox-addons.lib.${pkgs.system}.buildFirefoxXpiAddon {
            pname = "google-no-tracking-url";
            addonId = "jid1-zUrvDCat3xoDSQ@jetpack";
            version = "3.0.0";
            url =
              "https://addons.mozilla.org/firefox/downloads/file/706680/google_no_tracking_url-3.0.0.xpi";
            sha256 = "0iqnlcw714279mc4r3z06j3fhyb5cx2ghxh9816wn80ljzfhphzc";
            meta = { };
          })
        ];
        /* 
          ff 的 alias 使用起来没有 chrome 灵活。
          例如 alias 是 git：
          在 chrome 中输入 git+空格，会进入搜索待输入模式，但这时退格删除掉空格，git 就变成了待搜索词；
          而在 ff 中则以 git+空格 开头永远是识别为 alias。
        */
        search = {
          default = "Google";
          force = true;
          order = [
            "Google"
            "Hacker News"
            "Github"
            "Github Actions"
            "Github Nix"
            "Nixpkgs"
            "home-manager"
          ];
          engines = {
            "Github Actions" = {
              urls = [{
                template = "https://github.com/search?l=&p=1&q={searchTerms}+extension:yml+extension:yaml+path:.github/workflows&type=Code";
              }];
              definedAliases = [ "@actions" "@ci" ];
              iconUpdateURL = "https://github.com/favicon.ico";
            };
            "Github" = {
              urls = [{
                template = "https://github.com/search?q={searchTerms}";
              }];
              definedAliases = [ "@git" ];
              iconUpdateURL = "https://github.com/favicon.ico";
            };
            "Github Nix" = {
              urls = [{
                template = "https://github.com/search?q={searchTerms}+language%3Anix&type=code";
              }];
              definedAliases = [ "@gitnix" "gitnix" ];
              iconUpdateURL = "https://github.com/favicon.ico";
            };
            "Nixpkgs" = {
              urls = [{
                template = "https://github.com/search?q=repo%3ANixOS%2Fnixpkgs+{searchTerms}+language%3Anix&type=code";
              }];
              definedAliases = [ "@nixpkgs" ];
              iconUpdateURL = "https://github.com/favicon.ico";
            };
            "home-manager" = {
              urls = [{
                template = "https://github.com/search?q=repo%3Anix-community%2Fhome-manager+{searchTerms}+language%3Anix&type=code";
              }];
              definedAliases = [ "@hm" "hm" ];
              iconUpdateURL = "https://github.com/favicon.ico";
            };
            "Hacker News" = {
              urls = [{
                template = "https://www.google.com/search?q=site%3Anews.ycombinator.com+{searchTerms}";
              }];
              definedAliases = [ "@hn" "hn" ];
              iconUpdateURL = "https://www.ycombinator.com/favicon.ico";
            };
            "V2ex" = {
              urls = [{
                template = "https://www.google.com/search?q={searchTerms}+site:v2ex.com";
              }];
              definedAliases = [ "@v2ex" ];
              iconUpdateURL = "https://www.v2ex.com/favicon.ico";
            };

            "Bing".metaData.hidden = true;
            "eBay".metaData.hidden = true;
            "Amazon.com".metaData.hidden = true;
            "DuckDuckGo".metaData.hidden = true;
            "Google".metaData.alias = "@g"; # builtin engines only support specifying one additional alias
          };
        };
        # https://gist.github.com/0XDE57/fbd302cef7693e62c769
        # https://github.com/arkenfox/user.js/
        # https://github.com/Baitinq/nixos-config/blob/1ab479c29c7dc2629664ffb80653616666019b9e/hosts/home.nix#L200
        # 调试方法:
        #   cp ~/.mozilla/firefox/default/prefs.js /tmp/prefs.js
        #   修改配置
        #   diff ~/.mozilla/firefox/default/prefs.js /tmp/prefs.js
        extraConfig = lib.strings.concatStrings [
          (builtins.readFile "${inputs.arkenfox-userjs}/user.js")
          ''
            // Re-enables URL usages as a search bar.
            /* 0801 */ user_pref("keyword.enabled", true);
            user_pref("browser.search.suggest.enabled", true);    // 0804: live search suggestions
            // Re-allows COPY / CUT from "non-privileged" content as it actually breaks many websites.
            /* 2404 */ user_pref("dom.allow_cut_copy", true);
            // Disables RFP letter-boxing to avoid big white borders on screen.
            /* 4504 */ user_pref("privacy.resistFingerprinting.letterboxing", false);
            // Set UI density to normal
            user_pref("browser.uidensity", 0);
            // DRM content :(
            user_pref("media.gmp-widevinecdm.enabled", true);
            user_pref("media.eme.enabled", true);
            user_pref("webgl.disabled", false); // 4520
            user_pref("network.http.referer.XOriginTrimmingPolicy", 0);
            user_pref("privacy.clearOnShutdown.history", false); // 2811: don't clear history on close
            user_pref("browser.startup.page", 3);                 // 0102: enable session restore
            user_pref("signon.rememberSignons", true);           // 5003: enable saving passwords
            /* [UX,-HIST] Remember more closed tabs for undo. */
            user_pref("browser.sessionstore.max_tabs_undo", 27);                    // 1020
            /* [UX,-HIST] Restore all state for closed tab or previous session after Firefox restart. */
            user_pref("browser.sessionstore.privacy_level", 0);                     // 1021
            user_pref("browser.sessionstore.interval", 15000);                      // 1023
            /* [UX,-HIST] Enable search and form history. */
            user_pref("browser.formfill.enable", true);                             // 0860
            user_pref("general.autoScroll", true);
            //user_pref("network.cookie.lifetimePolicy", 0); //keep cookies 2801
            user_pref("network.cookie.cookieBehavior", 5); // 2701
            user_pref("privacy.clearOnShutdown.offlineApps", false);
            user_pref("privacy.cpd.offlineApps", false);
            user_pref("privacy.cpd.history", false); // 2812 to match when you use Ctrl-Shift-Del
            user_pref("privacy.clearOnShutdown.cookies", false);
            user_pref("privacy.clearOnShutdown.downloads", false);
            user_pref("privacy.clearOnShutdown.formdata", false);
            user_pref("privacy.clearOnShutdown.sessions", false);
            user_pref("extensions.pocket.enabled", false);        // 0900: disable Pocket
            user_pref("_user.js.baitinq", "Survived the overrides :)");
          ''
          ''
            // https://support.mozilla.org/en-US/questions/1283950
            user_pref("browser.urlbar.suggest.topsites", false);
            user_pref("browser.toolbars.bookmarks.visibility", "newtab");
            // user_pref("browser.bookmarks.addedImportButton", false);
            // disable Ask to save logins and passwords for websites
            user_pref("signon.rememberSignons", false);
            user_pref("network.dns.disableIPv6", false);
            // turn off secure DNS
            user_pref("doh-rollout.disable-heuristics", true);
            user_pref("network.trr.mode", 5);

            user_pref("extensions.formautofill.addresses.enabled", false);
            user_pref("extensions.formautofill.creditCards.enabled", false);
            user_pref("browser.formfill.enable", false);
            user_pref("dom.forms.autocomplete.formautofill", false);
          ''
        ];
      };
    };
  };
}
