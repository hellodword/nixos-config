{
  # https://github.com/CHN-beta/nixos/blob/4133a2af0c7a1abe4a2eb6eb947e61b6043be223/modules/basic.nix#L35
  # https://github.com/NixOS/nixos-hardware/tree/429f232fe1dc398c5afea19a51aad6931ee0fb89/dell/xps/13-7390#known-issues
  systemd.sleep.extraConfig = "SuspendState=freeze";
}
