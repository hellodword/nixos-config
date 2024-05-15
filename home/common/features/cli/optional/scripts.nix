{ lib, pkgs, ... }:

{
  programs.bash.initExtra = lib.mkAfter ''

    source <(cat ${../../../../../scripts/coderadio.completion.sh})

    source <(cat ${../../../../../scripts/suno-radio.completion.sh})

  '';

  home.packages = [

    (pkgs.writeShellApplication {
      name = "coderadio";
      runtimeInputs = with pkgs; [ curl ffmpeg-full ];
      text = builtins.readFile ../../../../../scripts/coderadio.sh;
    })

    (pkgs.writeShellApplication {
      name = "suno-radio";
      runtimeInputs = with pkgs; [ curl ffmpeg-full jq ];
      text = builtins.readFile ../../../../../scripts/suno-radio.sh;
    })

    (pkgs.writeShellApplication {
      name = "httpserver";
      runtimeInputs = with pkgs; [ coreutils docker ];
      text = builtins.readFile ../../../../../scripts/httpserver.sh;
    })

  ];
}
