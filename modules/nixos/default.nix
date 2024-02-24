{
  allowed-unfree = import ../common/allowed-unfree.nix;
  borgbackup2 = ./borgbackup2;
  adguardhome2 = ./adguardhome2.nix;
  sing-box = import ../nixos/sing-box.nix;
}
