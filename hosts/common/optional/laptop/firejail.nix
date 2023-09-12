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
    };
  };

  # https://nixos.wiki/wiki/Firejail#Add_Desktop_Icons_to_Firejailed_Apps
}
