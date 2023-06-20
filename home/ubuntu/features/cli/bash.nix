{ config, persistPath, ... }:

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
      "nixos-rebuild-switch" = "sudo echo; nixos-rebuild --use-remote-sudo switch --flake";
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
