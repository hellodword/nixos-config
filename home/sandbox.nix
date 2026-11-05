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
  apps = nixosConfig.site.apps.enable;
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
  keyring = "dbus-user.talk org.freedesktop.secrets";
  browserProfile = profile "firefox" desktopBus;
  firefox = wrap {
    package = config.programs.firefox.finalPackage;
    binaries = [ "firefox" ];
    profile = browserProfile;
  };
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
        (wrap {
          package = pkgs.google-chrome;
          arguments = [ "--password-store=gnome-libsecret" ];
          binaries = [
            "google-chrome"
            "google-chrome-stable"
          ];
          profile = profile "google-chrome" (desktopBus + keyring);
        })
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
          profile = profile "mpv" desktopBus;
        })
        (wrap {
          package = pkgs.feh;
          binaries = [ "feh" ];
          profile = profile "feh" ''
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
              whitelist ''${DOWNLOADS}
              include ${profiles}/whitelist-common.inc
            ''
          );
        })
      ];
  };
}
