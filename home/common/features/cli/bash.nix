{ config, lib, persistPath, nixosConfig, userName, ... }:

{
  # Broken symbol link
  # home.persistence = {
  #   "${persistPath}${config.home.homeDirectory}".files = [ ".bash_history" ];
  # };

  programs.bash = {
    enable = true;
    enableCompletion = true;
    enableVteIntegration = true;
    historyControl = [
      "ignorespace"
      "ignoredups"
    ];
    historyFile = "${persistPath}${config.home.homeDirectory}/.bash_history";
    historyFileSize = 100000;
    historyIgnore = [
      "ls"
      "cd"
    ];
    historySize = 10000;
    # ${pkgs.bash-completion}/share/bash-completion/completions/curl
    initExtra = lib.mkAfter ''
      _coderadio()
      {
          local cur prev
          _init_completion || return

          case $prev in
              --interface)
                  _available_interfaces -a
                  return
                  ;;
          esac

          if [[ $cur == -* ]]; then
              COMPREPLY=($(compgen -W '$(_parse_help "$1")' -- "$cur"))
          fi
      } &&
          complete -F _coderadio coderadio

      _suno_radio_completion() {
          local current_word="''${COMP_WORDS[COMP_CWORD]}"

          local options="status trending weekly monthly top"

          if [[ "$COMP_CWORD" -eq 1 ]]; then
              COMPREPLY=( $(compgen -W "$options" -- "$current_word") )
              return 0
          fi

          if [[ "$COMP_CWORD" -eq 2 ]]; then
              COMPREPLY=( $(compgen -W "$options" -- "$current_word") )
              return 0
          fi
      } && complete -F _suno_radio_completion suno-radio
    '';
    logoutExtra = "";
    profileExtra = "";
    sessionVariables = { };
    shellAliases = {
      "grep" = "grep --color=auto";
      "l" = "ls -CF";
      "la" = "ls -A";
      "ll" = "ls -alF";
      "ls" = "ls --color=auto";
      "7zaencrypt" = "7za -tzip -mem=AES256 -mx9 -p a";
      "emcc" = "docker run --rm -v $(pwd):/src -u $(id -u):$(id -g) emscripten/emsdk emcc";
      "gobuild" = "go build -trimpath -ldflags '-s -w -buildid='";
      "nixos-rebuild-boot" = "sudo echo; sudo chown ${userName} ${nixosConfig.systemd.services.nix-daemon.environment.TMPDIR} && env TMPDIR=${nixosConfig.systemd.services.nix-daemon.environment.TMPDIR} nixos-rebuild --use-remote-sudo boot --flake .#${nixosConfig.networking.hostName}";
      "nixos-rebuild-boot-offline" = "sudo echo; sudo chown ${userName} ${nixosConfig.systemd.services.nix-daemon.environment.TMPDIR} && env TMPDIR=${nixosConfig.systemd.services.nix-daemon.environment.TMPDIR} nixos-rebuild --use-remote-sudo boot --option substitute false --flake .#${nixosConfig.networking.hostName}";
      "sops-clone-keys" = "sudo cat ${persistPath}/var/lib/sops-nix/keys.txt > ${config.home.homeDirectory}/.config/sops/age/keys.txt";

      # https://unix.stackexchange.com/a/493065
      "sha3-224sum" = "openssl dgst -sha3-224";
      "sha3-256sum" = "openssl dgst -sha3-256";
      "sha3-384sum" = "openssl dgst -sha3-384";
      "sha3-512sum" = "openssl dgst -sha3-512";

      "rp" = "rp() { realpath \"\$(which \"\$1\")\" ;}; rp";
      "fb" = "touch /home/${userName}/Downloads/fb.db; mkdir -p /home/${userName}/Downloads/fb; docker run --name filebrowser --rm -u `id -u`:`id -g` -p 8000:80 -v /home/${userName}/Downloads/fb.db:/database.db -v /home/${userName}/Downloads/fb:/srv filebrowser/filebrowser";

      /*
        # httpserver_arg1="$1"
        # if [ -n "$httpserver_arg1" ]; then
        #     httpserver_arg1="$(readlink -f "$httpserver_arg1")"
        # else
        #     httpserver_arg1="$(pwd)"
        # fi

        # if [ -d "$httpserver_arg1" ]; then
        #     docker run --rm -v "$httpserver_arg1":/w:ro -w /w -p 8000:8000 -it python python -m http.server
        # elif [ -f "$httpserver_arg1" ]; then
        #     docker run --rm -v "$httpserver_arg1":/w/"$(basename "$httpserver_arg1")":ro -w /w -p 8000:8000 -it python python -m http.server
        # else
        #     echo "$httpserver_arg1"
        #     exit 1
        # fi
      */
      "httpserver" = ''httpserver() { httpserver_arg1="$1"; if [ -n "$httpserver_arg1" ]; then httpserver_arg1="$(readlink -f "$httpserver_arg1")"; else httpserver_arg1="$(pwd)"; fi; if [ -d "$httpserver_arg1" ]; then docker run --rm -v "$httpserver_arg1":/w:ro -w /w -p 8000:8000 -it python python -m http.server; elif [ -f "$httpserver_arg1" ]; then docker run --rm -v "$httpserver_arg1":/w/"$(basename "$httpserver_arg1")":ro -w /w -p 8000:8000 -it python python -m http.server; else ( echo "$httpserver_arg1"; exit 1; ) fi; }; httpserver'';

      "sing-box-log" = "sudo tail -f /var/log/sing-box/log";
      "sing-box-config" = "sudo cat /var/lib/sing-box/sing-box.json | jq";

      "nix-prefetch-url-sha256" = "nix-prefetch-url-sha256() { nix hash to-sri --type sha256 \"$(nix-prefetch-url $1)\"; }; nix-prefetch-url-sha256";
      "nix-prefetch-patch" = ''nix-prefetch-patch() { nix build --impure --expr "(import <nixpkgs> {}).fetchpatch { url = \"$1\"; }"; }; nix-prefetch-patch'';

      # https://coderadio.freecodecamp.org/
      # https://stackoverflow.com/questions/11831214/how-to-run-ffplay-as-a-window-less-process/53295994#53295994
      "coderadio" = ''coderadio () { curl -s https://coderadio-admin-v2.freecodecamp.org/listen/coderadio/radio.mp3 "$@" | ffplay -autoexit -nodisp -loglevel quiet -; }; coderadio'';

      "nix-outpath" = ''nix-outpath () { nix eval --impure --expr "(import <nixpkgs> {}).$1.outPath" | sed -E "s@(^\"|\"$)@@g"; }; nix-outpath'';
      "nix-meta" = ''nix-meta () { nix eval --impure --expr "builtins.toJSON (import <nixpkgs> {}).$1.meta" | jq -r | jq; }; nix-meta'';

      "gen-passwd" = ''gen-passwd () { openssl kdf -binary -keylen "''${1:-32}" -kdfopt digest:SHA512 -kdfopt pass:"$(openssl rand -base64 48)" -kdfopt salt:salt -kdfopt iter:1000000 PBKDF2 | openssl base64 | tr -d "=+/" | cut -c1-''${1:-32}; }; gen-passwd'';

      "code." = "code .";
      "ffmpeg" = "ffmpeg -hide_banner";
      "ffplay" = "ffplay -hide_banner -nodisp -autoexit";

      "suno-radio" = ''suno-radio () {  [[ "$1" == "" || "$1" == "status" ]] && curl -s https://gas-observe-ky-mention.trycloudflare.com/v1/playlist | jq || curl -s https://gas-observe-ky-mention.trycloudflare.com/v1/playlist/$1 | ffplay -autoexit -nodisp -; }; suno-radio'';
    };
    shellOptions = [
      "histappend"
      "checkwinsize"
      "extglob"
      "globstar"
      "checkjobs"
    ];
  };
}
