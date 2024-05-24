{ config, lib, persistPath, nixosConfig, userName, pkgs, ... }:

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
    initExtra = lib.mkAfter (lib.strings.concatStringsSep "\n\n" [
      (lib.optionalString nixosConfig.services.tailscale.enable ''source <(tailscale completion bash)'')
    ]);
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
      "nixos-rebuild-boot" = "sudo echo; sudo chown ${userName} ${nixosConfig.systemd.services.nix-daemon.environment.TMPDIR} && env TMPDIR=${nixosConfig.systemd.services.nix-daemon.environment.TMPDIR} nixos-rebuild --show-trace --verbose --use-remote-sudo boot --flake .#${nixosConfig.networking.hostName} |& ${pkgs.nix-output-monitor}/bin/nom";
      "nixos-rebuild-boot-offline" = "sudo echo; sudo chown ${userName} ${nixosConfig.systemd.services.nix-daemon.environment.TMPDIR} && env TMPDIR=${nixosConfig.systemd.services.nix-daemon.environment.TMPDIR} nixos-rebuild --use-remote-sudo boot --option substitute false --flake .#${nixosConfig.networking.hostName}";
      "sops-clone-keys" = "sudo cat ${persistPath}/var/lib/sops-nix/keys.txt > ${config.home.homeDirectory}/.config/sops/age/keys.txt";

      # https://unix.stackexchange.com/a/493065
      "sha3-224sum" = "openssl dgst -sha3-224";
      "sha3-256sum" = "openssl dgst -sha3-256";
      "sha3-384sum" = "openssl dgst -sha3-384";
      "sha3-512sum" = "openssl dgst -sha3-512";

      "rp" = "rp() { realpath \"\$(which \"\$1\")\" ;}; rp";
      "fb" = "touch /home/${userName}/Downloads/fb.db; mkdir -p /home/${userName}/Downloads/fb; docker run --name filebrowser --rm -u `id -u`:`id -g` -p 8000:80 -v /home/${userName}/Downloads/fb.db:/database.db -v /home/${userName}/Downloads/fb:/srv filebrowser/filebrowser";

      "sing-box-log" = "sudo tail -f /var/log/sing-box/log";
      "sing-box-config" = "sudo cat /var/lib/sing-box/sing-box.json | jq";

      "nix-prefetch-url-sha256" = "nix-prefetch-url-sha256() { nix hash to-sri --type sha256 \"$(nix-prefetch-url $1)\"; }; nix-prefetch-url-sha256";
      "nix-prefetch-patch" = ''nix-prefetch-patch() { nix build --impure --expr "(import <nixpkgs> {}).fetchpatch { url = \"$1\"; }"; }; nix-prefetch-patch'';

      "nix-outpath" = ''nix-outpath () { nix eval --impure --expr "(import <nixpkgs> {}).$1.outPath" | sed -E "s@(^\"|\"$)@@g"; }; nix-outpath'';
      "nix-meta" = ''nix-meta () { nix eval --impure --expr "builtins.toJSON ((import <nixpkgs> {}).$1.meta // { platforms = null; })" | sed -E "s@/nix/store/[^\n\/]+@https://github.com/NixOS/nixpkgs/blob/nixos-unstable@" | sed -E "s@\.nix:[0-9]+@\.nix@" | jq -r | jq; }; nix-meta'';

      "gen-passwd" = ''gen-passwd () { openssl kdf -binary -keylen "''${1:-32}" -kdfopt digest:SHA512 -kdfopt pass:"$(openssl rand -base64 48)" -kdfopt salt:salt -kdfopt iter:1000000 PBKDF2 | openssl base64 | tr -d "=+/" | cut -c1-''${1:-32}; }; gen-passwd'';

      "code." = "code .";
      "ffmpeg" = "ffmpeg -hide_banner";
      "ffplay" = "ffplay -hide_banner -nodisp -autoexit";

      "qrencode" = "docker run --rm -i --network none --runtime runsc leplusorg/qrcode qrencode";

      "nix-repl" = "nix repl --expr 'import <nixpkgs>{}'";

      "docker-rmi-none-images" = "docker images | grep '<none>' | awk '{print $3}' | xargs docker rmi";
      "docker-pull-my-images" = "docker images | grep -P '(ghcr.io/hellodword)|(mcr.microsoft.com)|(gcr.io/distroless)|(^filebrowser/filebrowser )|(^golang )|(^python )|(^nixos/nix )|(^node )|(lwthiker/curl-impersonate)|(leplusorg/qrcode)|(liwei2633/gopeed)|(mitmproxy/mitmproxy)|(^ubuntu )|(^alpine )' | awk '{print $1 \":\" $2}' | xargs -L 1 docker pull";

      "gopeed" = ''docker run --rm --name gopeed --runtime runsc -v "$HOME/Downloads/gopeed/Downloads":/app/Downloads -v "$HOME/Downloads/gopeed/storage":/app/storage -p 127.0.0.1:9999:9999 --user "$(id -u)":"$(id -g)" --entrypoint /app/gopeed liwei2633/gopeed'';
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
