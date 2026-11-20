{
  config,
  lib,
  pkgs,
  nixosConfig,
  ...
}:
let
  profiles = "${pkgs.firejail}/etc/firejail";
  wrap = import ../nix/firejail.nix { inherit pkgs; };
  apps = nixosConfig.site.apps.enable or false;
  productivity = nixosConfig.site.productivity.enable or false;
  common = extra: ''
    blacklist ${nixosConfig.site.storage.persistRoot}
    whitelist /run/current-system
    include ${profiles}/whitelist-run-common.inc
    ${extra}
  '';
  profile =
    name: extra:
    pkgs.writeText "${name}.profile" (
      common extra
      + ''
        include ${profiles}/${name}.profile
      ''
    );
  desktopBus = ''
    ignore dbus-user none
    dbus-user filter
    dbus-user.talk org.fcitx.Fcitx5
    dbus-user.talk org.freedesktop.IBus
    dbus-user.talk org.freedesktop.portal.*
    dbus-user.talk org.freedesktop.Notifications
  '';
  keyring = "dbus-user.talk org.freedesktop.secrets\n";
  browserProfile = profile "firefox" desktopBus;
  firefox = wrap {
    package = config.programs.firefox.finalPackage;
    binaries = [ "firefox" ];
    profile = browserProfile;
  };
  chrome = wrap {
    package = pkgs.google-chrome;
    arguments = [ "--password-store=gnome-libsecret" ];
    binaries = [
      "google-chrome"
      "google-chrome-stable"
    ];
    profile = profile "google-chrome" (
      desktopBus
      + keyring
      + ''
        noblacklist ''${DOCUMENTS}
        noblacklist ''${PICTURES}
        mkdir ''${HOME}/dev
        mkdir ''${HOME}/share
        mkdir ''${HOME}/.config/google-chrome-direct
        mkdir ''${HOME}/.cache/google-chrome-direct
        whitelist ''${HOME}/dev
        read-only ''${HOME}/dev
        whitelist ''${HOME}/share
        whitelist ''${DOCUMENTS}
        whitelist ''${PICTURES}
        whitelist ''${HOME}/.config/google-chrome-direct
        whitelist ''${HOME}/.cache/google-chrome-direct
      ''
    );
  };
  directBrowser =
    name: command:
    pkgs.writeShellScriptBin name ''
      dns=()
      while [[ "''${1:-}" == --dns ]]; do
        if [[ $# -lt 2 ]]; then
          echo 'Usage: ${name} [--dns SERVER]... [--] [browser arguments...]' >&2
          exit 2
        fi
        dns+=(--dns "$2")
        shift 2
      done
      if [[ "''${1:-}" == -- ]]; then shift; fi
      # Keep one process owner for the profile and its DNS lifetime.
      exec 9>"''${XDG_RUNTIME_DIR:?}/${name}.lock"
      if ! ${pkgs.util-linux}/bin/flock --nonblock 9; then
        message='${name} is running; close its window before starting another DNS environment.'
        if [[ ! -t 2 ]]; then
          ${pkgs.libnotify}/bin/notify-send -u normal "${name}" "$message" || true
        fi
        echo "$message" >&2
        exit 1
      fi
      /run/current-system/sw/bin/network-exclude "''${dns[@]}" -- ${command} "$@" || {
        status=$?
        if [[ ! -t 2 ]]; then
          ${pkgs.libnotify}/bin/notify-send -u critical "${name}" "Failed to launch excluded browser (exit $status)." || true
        fi
        exit "$status"
      }
    '';
  cliProfile = pkgs.writeText "bitwarden-cli.profile" ''
    blacklist ${nixosConfig.site.storage.persistRoot}
    noblacklist ''${HOME}/.config/Bitwarden CLI
    mkdir ''${HOME}/.config/Bitwarden CLI
    whitelist ''${HOME}/.config/Bitwarden CLI
    whitelist ''${DOWNLOADS}
    include ${profiles}/whitelist-common.inc
    include ${profiles}/disable-common.inc
    caps.drop all
    nonewprivs
    noroot
    seccomp
    private-dev
    private-tmp
    private-etc @tls-ca
    restrict-namespaces
    protocol unix,inet,inet6
    dbus-user none
    dbus-system none
  '';
in
{
  config = lib.mkIf (apps || productivity) {
    home.packages =
      lib.optionals apps [
        firefox
        chrome
        (wrap {
          package = pkgs.bitwarden-desktop;
          arguments = [ "--password-store=gnome-libsecret" ];
          binaries = [ "bitwarden" ];
          profile = profile "bitwarden" (desktopBus + keyring);
        })
        (wrap {
          package = pkgs.bitwarden-cli;
          binaries = [ "bw" ];
          profile = cliProfile;
        })
        (wrap {
          package = config.programs.mpv.finalPackage;
          binaries = [
            "mpv"
            "umpv"
            "mpv_identify.sh"
          ];
          profile = profile "mpv" (
            desktopBus
            + ''
              mkdir ''${HOME}/dev
              mkdir ''${HOME}/share
              whitelist ''${HOME}/dev
              read-only ''${HOME}/dev
              whitelist ''${HOME}/share
            ''
          );
        })
        (wrap {
          package = pkgs.feh;
          binaries = [ "feh" ];
          profile = profile "feh" ''
            mkdir ''${HOME}/dev
            mkdir ''${HOME}/share
            mkdir ''${HOME}/.codex/generated_images
            whitelist ''${HOME}/dev
            read-only ''${HOME}/dev
            whitelist ''${HOME}/share
            whitelist ''${HOME}/.codex/generated_images
            read-only ''${HOME}/.codex/generated_images
            whitelist ''${HOME}/.config/feh
            whitelist ''${PICTURES}
            whitelist ''${DOWNLOADS}
            whitelist ''${DOCUMENTS}
            include ${profiles}/whitelist-common.inc
          '';
        })
        (wrap {
          package = pkgs.sqlitebrowser;
          binaries = [ "sqlitebrowser" ];
          profile = profile "sqlitebrowser" desktopBus;
        })
        (pkgs.writeShellScriptBin "firefox-origin" ''
          exec ${firefox}/bin/firefox --no-remote -P origin "$@"
        '')
      ]
      ++ lib.optionals (apps && (nixosConfig.site.network.lockdown.enable or false)) [
        (directBrowser "firefox-direct" "${firefox}/bin/firefox --no-remote -P direct")
        (directBrowser "google-chrome-direct" ''${chrome}/bin/google-chrome --user-data-dir="$HOME/.config/google-chrome-direct" --disk-cache-dir="$HOME/.cache/google-chrome-direct"'')
      ]
      ++ lib.optionals productivity [
        (wrap {
          package = pkgs.anytype;
          binaries = [ "anytype" ];
          arguments = [ "--password-store=gnome-libsecret" ];
          profile = pkgs.writeText "anytype.profile" (
            common (
              desktopBus
              + keyring
              + ''

                noblacklist ''${HOME}/.config/anytype
                mkdir ''${HOME}/.config/anytype
                whitelist ''${HOME}/.config/anytype
                whitelist ''${DOCUMENTS}
                whitelist ''${DOWNLOADS}
                include ${profiles}/electron-common-hardened.inc.profile
                include ${profiles}/electron-common.profile
              ''
            )
          );
        })
        (wrap {
          package = pkgs.remmina;
          binaries = [
            "remmina"
            "remmina-file-wrapper"
          ];
          profile = profile "remmina" (
            desktopBus
            + keyring
            + ''

              dbus-user.own org.remmina.Remmina
              dbus-user.own org.kde.StatusNotifierItem-*
              dbus-user.talk org.kde.StatusNotifierWatcher
              mkdir ''${HOME}/.config/remmina
              mkdir ''${HOME}/.local/share/remmina
              mkdir ''${HOME}/.config/freerdp
              noblacklist ''${HOME}/.config/freerdp
              whitelist ''${HOME}/.config/remmina
              whitelist ''${HOME}/.local/share/remmina
              whitelist ''${HOME}/.config/freerdp
              whitelist ''${HOME}/.ssh
              read-only ''${HOME}/.ssh
              whitelist ''${DOWNLOADS}
              include ${profiles}/whitelist-common.inc
            ''
          );
        })
      ];
  };
}
