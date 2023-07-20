{ lib, pkgs, config, ... }:

let
  fetch-bing-wallpaper = pkgs.writeShellApplication {
    name = "fetch-bing-wallpaper";
    runtimeInputs = with pkgs; [ curl coreutils gnugrep ];
    text = ''
      result="$(curl -s -f 'http://www.bing.com/HPImageArchive.aspx?format=xml&idx=0&n=1&mkt=en-WW')"
      fullstartdate="$(echo "$result" | grep -oP '(?<=<fullstartdate>)\d+(?=</fullstartdate>)')"
      filename="$fullstartdate"".jpg"
      if [ ! -f "${out}/$filename" ]; then
        url="$(echo "$result" | grep -oP '(?<=<url>)[^<]+(?=</url>)')"
        curl -f --output "/tmp/$filename" "http://www.bing.com$url"
        mv "/tmp/$filename" "${out}/$filename"
      fi
    '';
  };
  out = "${config.home.homeDirectory}/Pictures/wallpaper";
in
{
  services.random-background = {
    enable = true;
    interval = "5m";
    # # https://github.com/considerate/home/blob/8ff164b1fcf16e233900cc291afc06c8db9aa44f/wallpaper/default.nix#LL3C1-L12C5
    # imageDirectory =
    #   let
    #     wallpapers = pkgs.runCommand "collect-wallpapers" { } ''
    #       mkdir $out
    #       # cp ${pkgs.nixos-artwork.wallpapers.simple-dark-gray.kdeFilePath} $out

    #       ${lib.concatStringsSep "\n" (
    #         lib.mapAttrsToList (name: value: lib.optionalString
    #             (lib.hasAttrByPath ["kdeFilePath"] value)
    #             ''cp -f ${value.kdeFilePath} $out/'')
    #           pkgs.nixos-artwork.wallpapers)};
    #     '';
    #   in
    #   "${wallpapers}";
    imageDirectory = "${config.home.homeDirectory}/Pictures/wallpaper";
  };

  home.activation.copyWallpapers = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    mkdir -p "${out}"

    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: value: lib.optionalString
          (lib.hasAttrByPath ["kdeFilePath"] value)
          ''cp -f ${value.kdeFilePath} ${out}/'')
        pkgs.nixos-artwork.wallpapers)};
  '';

  systemd.user.services.fetch-bing-wallpaper = {
    Service = {
      Type = "oneshot";
      ExecStart = "${fetch-bing-wallpaper}/bin/fetch-bing-wallpaper";
      Restart = "on-failure";
      RestartSec = "5m";
    };
  };
  systemd.user.timers.fetch-bing-wallpaper = {
    Timer = {
      OnBootSec = "10m";
      OnUnitInactiveSec = "1h";
    };
    Install = { WantedBy = [ "timers.target" ]; };
  };
}
