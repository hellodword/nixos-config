{ pkgs, inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../common/optional/fix-sleep.nix
    ../common/optional/intel-tearing.nix
  ]
  ++
  [
    ../common/optional/laptop
  ]
  ;

  networking.hostName = "laptop3";

  boot.kernelPackages = pkgs.linuxPackages_6_1;
  boot.kernelPatches = [
    # {
    #   # https://gitlab.freedesktop.org/drm/intel/-/issues/6454#note_1559405
    #   name = "0001-overriding-vbt-to-detect-hdmi.patch";
    #   # patch = (pkgs.fetchpatch {
    #   #   url = "https://gitlab.freedesktop.org/drm/intel/uploads/ca3dad2b6809e0edfeea5a2d64ed1e26/0001-overriding-vbt-to-detect-hdmi.patch";
    #   #   sha256 = "0dpr864v7r59ghyc82nsbj1jcdhsm93lmd10c091zy1dz3nwi73r";
    #   # });
    #   /*
    #     git clone --depth=1 -b v6.3.9 git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git linux-6.3.9
    #     vim drivers/gpu/drm/i915/display/intel_ddi.c
    #     git diff drivers/gpu/drm/i915/display/intel_ddi.c > 0001-overriding-vbt-to-detect-hdmi.patch
    #   */
    #   patch = ./0001-overriding-vbt-to-detect-hdmi.patch;
    # }
    {
      # https://github.com/CHN-beta/nixos/blob/4133a2af0c7a1abe4a2eb6eb947e61b6043be223/modules/boot/hdmi.patch
      name = "0002-hdmi.patch";
      patch = ./0002-hdmi.patch;
    }
  ];
  boot.kernelModules = [ "lkrg" ];

  users.users."ubuntu".openssh.authorizedKeys.keys = [
    "${inputs.nixos-privates.ssh."laptop".authorizedKey}"
  ];

  system.stateVersion = "22.11";
}
