{ pkgs, ... }:

{
  me.allowedUnfreePkg = [ pkgs.p7zip ];

  environment.systemPackages = with pkgs; [
    nix-prefetch
    nix-prefetch-scripts
    sysstat
    aria
    usbutils
    brotli
    fzf
    fd
    ripgrep
    hyperfine
    atuin

    (p7zip.override { enableUnfree = true; }) # unrar
  ];
}
