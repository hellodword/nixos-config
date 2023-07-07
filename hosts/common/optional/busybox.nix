{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    (busybox.override { enableAppletSymlinks = false; })
  ];
}
