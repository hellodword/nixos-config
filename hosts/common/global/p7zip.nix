{ pkgs, ... }:

{
  me.allowedUnfreePkg = [
    "p7zip"
  ];

  environment.systemPackages = with pkgs; [
    (p7zip.override { enableUnfree = true; }) # unrar
  ];
}
