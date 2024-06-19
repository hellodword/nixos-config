{ lib, pkgs, config, nixosConfig, ... }:

let
  wallpapers = "${config.home.homeDirectory}/Pictures/wallpaper";
  fetch-bing-wallpaper = pkgs.writeShellApplication {
    name = "fetch-bing-wallpaper";
    runtimeInputs = with pkgs; [ curl coreutils gnugrep ];
    text = ''
      result="$(curl -s -f 'http://www.bing.com/HPImageArchive.aspx?format=xml&idx=0&n=1&mkt=en-WW')"
      fullstartdate="$(echo "$result" | grep -oP '(?<=<fullstartdate>)\d+(?=</fullstartdate>)')"
      filename="$fullstartdate"".jpg"
      if [ ! -f "${wallpapers}/$filename" ]; then
        url="$(echo "$result" | grep -oP '(?<=<url>)[^<]+(?=</url>)')"
        tmp="$(mktemp)"
        curl -f --output "$tmp" "http://www.bing.com$url"
        mv "$tmp" "${wallpapers}/$filename"
      fi
    '';
  };
  random-background-sway = pkgs.writeShellApplication {
    name = "random-background-sway";
    runtimeInputs = with pkgs; [ jq sway findutils ];
    # https://forum.manjaro.org/t/is-there-a-simple-way-to-set-up-dynamic-wallpaper-switching-in-sway-for-dual-displays/85568/4
    text = ''
      Display=(${wallpapers}/*)
      swaymsg -t get_outputs | jq -r '.[] | select(.active == true) | .name' | xargs -I {} swaymsg output "{}" bg "''${Display[''$((0 + RANDOM % ''${#Display[@]}))]}" fill
    '';
  };
  X = nixosConfig.services.xserver.windowManager.i3.enable;
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

  systemd.user.services.random-background.Service = if X then { } else {
    ExecStart = lib.mkForce "${lib.getExe random-background-sway}";
  };

  home.activation.copyWallpapers = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    mkdir -p "${wallpapers}"

    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: value: lib.optionalString
          (lib.hasAttrByPath ["kdeFilePath"] value)
          ''cp -f ${value.kdeFilePath} ${wallpapers}/'')
        pkgs.nixos-artwork.wallpapers)};

    rm -f ${wallpapers}/nix-wallpaper-simple-dark-gray_bootloader.png
    rm -f ${wallpapers}/nix-wallpaper-simple-red.png
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
