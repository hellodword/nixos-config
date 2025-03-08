{
  pkgs,
  userName,
  ...
}:

{
  imports =
    [
      ./hardware-configuration.nix
      ../common/optional/fix-sleep.nix
      ../common/optional/intel-tearing.nix
    ]
    ++ [
      ../common/optional/laptop
      # ../common/optional/chromium-based-security-issue.nix
    ];

  networking.hostName = "laptop2";

  boot.kernelPackages = pkgs.linuxPackages_6_6; # _hardened;
  boot.kernelModules = [
    # "lkrg"
  ];

  home-manager.users."${userName}" = import ../../home/laptop;

  system.stateVersion = "22.11";
}
