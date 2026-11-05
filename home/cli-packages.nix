{ pkgs, ... }:
{
  home.packages =
    with pkgs;
    [
      screen
      bat
      zoxide
      starship
      gnupg
      fzf
      fd
      ripgrep
      hyperfine
      aria2
      sysstat
      usbutils
      wget
      tcpdump
      ipset
      inotify-tools
      inetutils
      nix-prefetch
      nix-prefetch-scripts
      (p7zip.override { enableUnfree = true; })
    ]
    ++ (import ../nix/user-tools.nix { inherit pkgs; });
}
