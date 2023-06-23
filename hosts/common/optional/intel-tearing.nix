# https://github.com/floscr/dotfiles/blob/e2493127aaaa12b1ad4d21daef63297be0a85184/hosts/thinknixx1/hardware-configuration.nix#L23-L37

{
  # Remove screen tearing
  environment.etc."X11/xorg.conf.d/20-intel.conf" = {
    text = ''
      Section "Device"
        Identifier "Intel Graphics"
        Driver "intel"
        Option "TearFree" "true"
        Option "AccelMethod" "sna"
        Option "SwapbuffersWait" "true"
        Option "TripleBuffer" "true"
        Option "VariableRefresh" "true"
        Option "DRI" "2"
      EndSection
    '';
  };
}
