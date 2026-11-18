{ pkgs, ... }:
{
  programs.vim = {
    enable = true;
    defaultEditor = true;
  };

  environment.systemPackages = with pkgs; [
    screen
    wget
    git
    rsync
    tree
    file
    unzip
    ripgrep
    dnsutils
    openssl
    nmap
    tcpdump
    mtr
    lsof
    strace
    htop
    ncdu
  ];

  environment.shellAliases = {
    ll = "ls -alh";
    la = "ls -A";
    ".." = "cd ..";
  };
}
