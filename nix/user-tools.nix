{ pkgs }:
let
  pythonTool =
    name: script: args: inputs:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [ pkgs.python3 ] ++ inputs;
      text = ''exec python3 ${script} ${args} "$@"'';
    };
in
[
  (pkgs.writeShellApplication {
    name = "apkid";
    runtimeInputs = with pkgs; [ docker ];
    text = ''
      set +o nounset

      #!/bin/bash
      # This will simply take the argument passed to it,
      # parse the directory and bind it as a read-only mount point on the container
      # and pass in the filename as the argument to APKiD
      #
      # This can easily be set to an alias and added to your .profile or whatever

      # This assumes file target is last argument!
      TARGET="''${*: -1}"
      INPUT_DIR="$(cd "$(dirname "$TARGET")" && pwd -P)"
      INPUT_FILE="$(basename "$TARGET")"

      docker run --network=none --runtime=runsc --rm --volume "$INPUT_DIR/$INPUT_FILE":"/input/$INPUT_FILE":ro -i ghcr.io/hellodword/apkid "/input/$INPUT_FILE" "''${@:0:$#}";
    '';
  })
  (pythonTool "coderadio" ../scripts/cli/radio.py "coderadio" [ pkgs.ffmpeg-full ])
  (pythonTool "suno-radio" ../scripts/cli/radio.py "suno-radio" [ pkgs.ffmpeg-full ])
  (pythonTool "docker-pull-my-images" ../scripts/cli/docker_pull.py "" [ pkgs.docker ])
]
