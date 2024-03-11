{ config, persistPath, nixosConfig, userName, ... }:

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
    # initExtra = builtins.readFile ./.bashrc;
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

      "nix-prefetch-url-sha256" = "nix-prefetch-url-sha256() { nix hash to-sri --type sha256 \"$(nix-prefetch-url $1)\"; }; nix-prefetch-url-sha256";
      "nix-prefetch-patch" = ''nix-prefetch-patch() { nix build --impure --expr "(import <nixpkgs> {}).fetchpatch { url = \"$1\"; }"; }; nix-prefetch-patch'';
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
