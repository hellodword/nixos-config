{
  nix.gc = {
    automatic = true;
    dates = "weekly";
    # Delete older generations too
    options = "--delete-older-than 14d";
    persistent = true;
    randomizedDelaySec = "45min";
  };
}
