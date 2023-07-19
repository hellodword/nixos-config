{ lib, ... }:

{
  xdg.mime.enable = lib.mkForce false;
}
