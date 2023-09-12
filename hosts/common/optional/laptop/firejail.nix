{ pkgs, lib, ... }:

{
  programs.firejail = {
    enable = true;
    wrappedBinaries = {
      # firefox = {
      #   profile = "${pkgs.firejail}/etc/firejail/firefox.profile";
      #   executable = "${lib.getBin pkgs.firefox}/bin/firefox";
      #   desktop = "${pkgs.firefox}/share/applications/firefox.desktop";
      # };
      mpv = {
        profile = "${pkgs.firejail}/etc/firejail/mpv.profile";
        executable = "${lib.getBin pkgs.mpv}/bin/mpv";
        desktop = "${pkgs.mpv}/share/applications/mpv.desktop";
      };
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
    };
  };

  # https://nixos.wiki/wiki/Firejail#Add_Desktop_Icons_to_Firejailed_Apps
}
