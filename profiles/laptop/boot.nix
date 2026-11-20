{ lib, ... }:
{
  boot.plymouth = {
    enable = lib.mkDefault true;
    theme = lib.mkDefault "breeze";
  };
}
