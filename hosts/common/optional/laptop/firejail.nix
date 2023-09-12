{ pkgs, lib, ... }:

{
  # TODO hm 条件开启

  programs.firejail = {
    enable = true;
    wrappedBinaries = {
      # firefox = {
      #   profile = "${pkgs.firejail}/etc/firejail/firefox.profile";
      #   executable = "${lib.getBin pkgs.firefox}/bin/firefox";
      #   desktop = "${pkgs.firefox}/share/applications/firefox.desktop";
      # };
      chromium = {
        profile = "${pkgs.firejail}/etc/firejail/chromium.profile";
        executable = "${lib.getBin pkgs.chromium}/bin/chromium";
        desktop = "${pkgs.chromium}/share/applications/chromium-browser.desktop";
      };
      bitwarden = {
        profile = "${pkgs.firejail}/etc/firejail/bitwarden.profile";
        executable = "${lib.getBin pkgs.bitwarden}/bin/bitwarden";
        desktop = "${pkgs.bitwarden}/share/applications/bitwarden.desktop";
      };
      flameshot = {
        profile = "${pkgs.firejail}/etc/firejail/flameshot.profile";
        executable = "${lib.getBin pkgs.flameshot}/bin/flameshot";
        desktop = "${pkgs.flameshot}/share/applications/org.flameshot.Flameshot.desktop";
      };
      peek = {
        profile = "${pkgs.firejail}/etc/firejail/peek.profile";
        executable = "${lib.getBin pkgs.peek}/bin/peek";
        desktop = "${pkgs.peek}/share/applications/com.uploadedlobster.peek.desktop";
      };
      qrencode = {
        profile = "${pkgs.firejail}/etc/firejail/qrencode.profile";
        executable = "${lib.getBin pkgs.qrencode}/bin/qrencode";
      };
      thunar = {
        profile = "${pkgs.firejail}/etc/firejail/thunar.profile";
        executable = "${lib.getBin pkgs.xfce.thunar}/bin/thunar";
        desktop = "${pkgs.xfce.thunar}/share/applications/thunar.desktop";
      };
      # feh = {
      #   profile = "${pkgs.firejail}/etc/firejail/feh.profile";
      #   executable = "${lib.getBin pkgs.feh}/bin/feh";
      # };
      sqlitebrowser = {
        profile = "${pkgs.firejail}/etc/firejail/sqlitebrowser.profile";
        executable = "${lib.getBin pkgs.sqlitebrowser}/bin/sqlitebrowser";
        desktop = "${pkgs.sqlitebrowser}/share/applications/sqlitebrowser.desktop";
      };
      zathura = {
        profile = "${pkgs.firejail}/etc/firejail/zathura.profile";
        executable = "${lib.getBin pkgs.zathura}/bin/zathura";
        desktop = "${pkgs.zathura}/share/applications/org.pwmt.zathura.desktop";
      };
    };
  };

  # https://nixos.wiki/wiki/Firejail#Add_Desktop_Icons_to_Firejailed_Apps
}
