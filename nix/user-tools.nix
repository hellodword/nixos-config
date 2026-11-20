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
      if [ "$#" -eq 0 ]; then
        exec docker run --network=none --runtime=runsc --rm -i ghcr.io/hellodword/apkid --help
      fi
      for arg in "$@"; do
        case "$arg" in
          -h | --help | --version)
            exec docker run --network=none --runtime=runsc --rm -i ghcr.io/hellodword/apkid "$@"
            ;;
        esac
      done

      TARGET="''${*: -1}"
      if [ ! -e "$TARGET" ]; then
        echo "apkid: target file does not exist: $TARGET" >&2
        exit 2
      fi
      INPUT_DIR="$(cd "$(dirname "$TARGET")" && pwd -P)"
      INPUT_FILE="$(basename "$TARGET")"

      exec docker run --network=none --runtime=runsc --rm \
        --volume "$INPUT_DIR/$INPUT_FILE":"/input/$INPUT_FILE":ro \
        -i ghcr.io/hellodword/apkid "/input/$INPUT_FILE" "''${@:1:$#-1}"
    '';
  })
  (pythonTool "coderadio" ../scripts/cli/radio.py "coderadio" [ pkgs.ffmpeg-full ])
  (pythonTool "suno-radio" ../scripts/cli/radio.py "suno-radio" [ pkgs.ffmpeg-full ])
  (pythonTool "docker-pull-my-images" ../scripts/cli/docker_pull.py "" [ pkgs.docker ])
]
