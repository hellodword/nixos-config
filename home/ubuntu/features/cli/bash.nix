{ config, persistPath, nixosConfig, ... }:

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
      "nixos-rebuild-boot" = "sudo echo; sudo chown ubuntu /var/cache/nix && env TMPDIR=/var/cache/nix nixos-rebuild --use-remote-sudo boot --flake .#${nixosConfig.networking.hostName}";
      "nixos-rebuild-boot-offline" = "sudo echo; sudo chown ubuntu /var/cache/nix && env TMPDIR=/var/cache/nix nixos-rebuild --use-remote-sudo boot --option substitute false --flake .#${nixosConfig.networking.hostName}";
      "sops-clone-keys" = "sudo cat ${persistPath}/var/lib/sops-nix/keys.txt > ${config.home.homeDirectory}/.config/sops/age/keys.txt";

      # https://unix.stackexchange.com/a/493065
      "sha3-224sum" = "openssl dgst -sha3-224";
      "sha3-256sum" = "openssl dgst -sha3-256";
      "sha3-384sum" = "openssl dgst -sha3-384";
      "sha3-512sum" = "openssl dgst -sha3-512";
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
