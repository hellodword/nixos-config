{
  lib,
  inputs,
  pkgs,
  persistPath,
  config,
  ...
}:

let
  violentmonkey = builtins.fromJSON (
    builtins.readFile "${inputs.reproducible-violentmonkey}/info.json"
  );
  userjs =
    pkgs.runCommand "arkenfox-userjs"
      {
        preferLocalBuild = true;
        allowSubstitutes = false;
        # take precedence over non-firejailed versions
        meta.priority = -1;
      }
      ''
        set -x
        mkdir -p $out
        cat "${inputs.arkenfox-userjs}/user.js" > $out/user.js
        grep -i clearonshutdown $out/user.js
        sed -i -e '/\/\*\*\* \[SECTION 2800\]/,/\/\*\*\* \[SECTION /s/user_pref.*//' $out/user.js
        ! grep -iP '^user_pref\("[^\n"]+\.clearonshutdown' $out/user.js
      '';
  configPath = "${config.xdg.configHome}/mozilla/firefox";
in
{
  # TODO backup
  home = {
    sessionVariables.BROWSER = "firefox";
    persistence = {
      "${persistPath}".directories = [
        (builtins.replaceStrings [ "${config.home.homeDirectory}/" ] [ "" ] configPath)
        ".cache/mozilla/firefox"
      ];
    };
  };

  me.mimeApps.defApps.webBrowser = "firefox.desktop";

  me.exitProcess = [
    "firefox"
  ];

  /*
    TODO ff sync self-hosted
        https://github.com/mozilla-services/syncstorage-rs/issues/1428
        https://github.com/mozilla-services/syncstorage-rs/issues/825
        https://hacks.mozilla.org/2018/11/firefox-sync-privacy/
  */
  programs.firefox = {
    enable = true;
    package = pkgs.firefox;
    inherit configPath;
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
        bookmarks.force = true;
        bookmarks.settings = [
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
              {
                name = "Anna’s Archive";
                url = "https://annas-archive.org";
              }
              {
                name = "Google Translate";
                url = "https://translate.google.com/?sl=auto&tl=zh-CN&op=translate";
              }
              {
                name = "Buddy's Github Events";
                url = "https://lawvs.github.io/buddy-github-events/";
              }
              {
                name = "番組表";
                url = "https://bgmlist.com";
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
                url = "https://nix-community.github.io/home-manager/options.xhtml";
              }
              {
                name = "Nixpkgs Pull Request Tracker";
                url = "https://nixpkgs-tracker.ocfox.me";
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
        extensions.packages = [
          (inputs.firefox-addons.lib.${pkgs.stdenv.hostPlatform.system}.buildFirefoxXpiAddon {
            # https://addons.mozilla.org/en-US/firefox/addon/violentmonkey/
            pname = "violentmonkey";
            addonId = "{aecec67f-0d10-4fa7-b7c7-609a2db280cf}";
            version = violentmonkey.version;
            url = violentmonkey.link;
            # nix hash to-sri --type sha256 "$(nix-prefetch-url $url)"
            sha256 = violentmonkey.fileHash;
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
          default = "google";
          force = true;
          order = [
            "google"
            "Hacker News"
            "Github"
            "Github Actions"
            "Github Nix"
            "Nixpkgs"
            "home-manager"
            "Google Translate"
          ];
          engines = {
            "Github Actions" = {
              urls = [
                {
                  template = "https://github.com/search?q={searchTerms}+%28path%3A.github%2Fworkflows%2F*.yml+OR+path%3A.github%2Fworkflows%2F*.yaml%29&type=code";
                }
              ];
              definedAliases = [
                "@actions"
                "@ci"
              ];
              icon = "https://github.com/favicon.ico";
            };
            "Github" = {
              urls = [
                {
                  template = "https://github.com/search?q={searchTerms}";
                }
              ];
              definedAliases = [ "@git" ];
              icon = "https://github.com/favicon.ico";
            };
            "Github Nix" = {
              urls = [
                {
                  template = "https://github.com/search?q={searchTerms}+language%3Anix&type=code";
                }
              ];
              definedAliases = [
                "@gitnix"
                "gitnix"
              ];
              icon = "https://github.com/favicon.ico";
            };
            "Nix Noogle" = {
              urls = [
                {
                  template = "https://noogle.dev/q?term={searchTerms}";
                }
              ];
              definedAliases = [
                "@noogle"
                "noogle"
                "@nix1"
              ];
              icon = "https://noogle.dev/favicon.png";
            };
            "Nix Nixhub" = {
              urls = [
                {
                  template = "https://www.nixhub.io/search?q={searchTerms}";
                }
              ];
              definedAliases = [
                "@nixhub"
                "nixhub"
                "@nix2"
              ];
              icon = "https://www.nixhub.io/favicon.ico";
            };
            "Nix MyNixOS" = {
              urls = [
                {
                  template = "https://mynixos.com/search?q={searchTerms}";
                }
              ];
              definedAliases = [
                "@mynixos"
                "mynixos"
                "@nix3"
              ];
              icon = "https://mynixos.com/favicon.ico";
            };
            "Nix package versions" = {
              urls = [
                {
                  template = "https://lazamar.co.uk/nix-versions/?channel=nixpkgs-unstable&package={searchTerms}";
                }
              ];
              definedAliases = [ "@nix4" ];
              icon = "https://nixos.org/favicon.png";
            };
            "Nixpkgs" = {
              urls = [
                {
                  template = "https://github.com/search?q=repo%3ANixOS%2Fnixpkgs+{searchTerms}+language%3Anix&type=code";
                }
              ];
              definedAliases = [ "@nixpkgs" ];
              icon = "https://github.com/favicon.ico";
            };
            "home-manager" = {
              urls = [
                {
                  template = "https://github.com/search?q=repo%3Anix-community%2Fhome-manager+{searchTerms}+language%3Anix&type=code";
                }
              ];
              definedAliases = [
                "@hm"
                "hm"
              ];
              icon = "https://github.com/favicon.ico";
            };
            "Hacker News" = {
              urls = [
                {
                  template = "https://google.com/search?q=site%3Anews.ycombinator.com+{searchTerms}";
                }
              ];
              definedAliases = [
                "@hn"
                "hn"
              ];
              icon = "https://www.ycombinator.com/favicon.ico";
            };
            "V2ex" = {
              urls = [
                {
                  template = "https://google.com/search?q={searchTerms}+site:v2ex.com";
                }
              ];
              definedAliases = [ "@v2ex" ];
              icon = "https://www.v2ex.com/favicon.ico";
            };
            "Google Translate" = {
              urls = [
                {
                  template = "https://translate.google.com/?sl=auto&tl=zh-CN&op=translate&text={searchTerms}";
                }
              ];
              definedAliases = [ "@translate" ];
              icon = "https://translate.google.com/favicon.ico";
            };
            "LET" = {
              urls = [
                {
                  template = "https://google.com/search?q={searchTerms}+site:lowendtalk.com";
                }
              ];
              definedAliases = [ "@let" ];
              icon = "https://lowendtalk.com/uploads/LowEndTalk.ico";
            };

            "bing".metaData.hidden = true;
            "ebay".metaData.hidden = true;
            "amazondotcom-us".metaData.hidden = true;
            "ddg".metaData.hidden = true;
            "google".metaData.alias = "@g"; # builtin engines only support specifying one additional alias
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
          (builtins.readFile "${userjs}/user.js")
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
            user_pref("privacy.cpd.offlineApps", false);
            user_pref("privacy.cpd.history", false); // 2812 to match when you use Ctrl-Shift-Del
            user_pref("extensions.pocket.enabled", false);        // 0900: disable Pocket
            user_pref("_user.js.baitinq", "Survived the overrides :)");

            user_pref("privacy.clearOnShutdown.cache", false);     // [DEFAULT: true]
            user_pref("privacy.clearOnShutdown_v2.cache", false);  // [FF128+] [DEFAULT: true]
            user_pref("privacy.clearOnShutdown.downloads", false); // [DEFAULT: true]
            user_pref("privacy.clearOnShutdown.formdata", false);  // [DEFAULT: true]
            user_pref("privacy.clearOnShutdown.history", false);   // [DEFAULT: true]
            user_pref("privacy.clearOnShutdown_v2.historyFormDataAndDownloads", false); // [FF128+] [DEFAULT: true]
            user_pref("privacy.clearOnShutdown.cookies", false); // Cookies
            user_pref("privacy.clearOnShutdown.offlineApps", false); // Site Data
            user_pref("privacy.clearOnShutdown.sessions", false);  // Active Logins [DEFAULT: true]
            user_pref("privacy.clearOnShutdown_v2.cookiesAndStorage", false); // Cookies, Site Data, Active Logins [FF128+]
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

            user_pref("signon.rememberSignons", true);
            user_pref("signon.autofillForms", true);
            user_pref("signon.management.page.breach-alerts.enabled", false);
            user_pref("signon.firefoxRelay.feature", "disabled");
            user_pref("signon.generation.enabled", false);

            user_pref("browser.search.suggest.enabled", false);

            # disable HTTP/3
            user_pref("network.http.http3.enable", false);

            # do not upgrade extensions automatically
            user_pref("extensions.update.autoUpdateDefault", false);
          ''
        ];
      };
    };
  };
}
