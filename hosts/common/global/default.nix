# This file (and the global directory) holds config that i use on all hosts
{
  inputs,
  outputs,
  pkgs,
  commonArgs,
  ...
}:

{
  imports = [
    inputs.home-manager.nixosModules.home-manager
    ./vim.nix
    ./locale.nix
    ./nix.nix
    ./bash.nix
    ./optin-persistence.nix
    ./sops.nix
    ./systemd-initrd.nix
    ./inetutils.nix
    ./openssh-client.nix
    ./fhs.nix
  ] ++ (builtins.attrValues outputs.nixosModules);

  system.configurationRevision = inputs.self.rev or "dirty";

  nixpkgs = {
    # You can add overlays here
    overlays = [
      # Add overlays your own flake exports (from overlays and pkgs dir):
      outputs.overlays.additions
      outputs.overlays.modifications
    ];
  };

  home-manager.extraSpecialArgs = {
    inherit inputs outputs;
  } // commonArgs;

  environment.systemPackages = with pkgs; [
    wget
    file
    tree
    unzip
    tcpdump
    ipset
    libtree
    # compsize # calc btrfs compression ratio
    lsof
    git
    screen
    openssl_legacy
    iptables
  ];

  # # https://github.com/mcdonc/.nixconfig/blob/bb1d1458f2558c16d1451f30a619fa9e14733996/videos/stopdhcp/script.rst
  # # https://github.com/NixOS/nixpkgs/blob/5747afd08e90b710b2dd2ef01af808b17bfbd1fe/nixos/modules/services/networking/iscsi/root-initiator.nix#L91-L95
  # # (maybe) fix: a stop job is running for dhcp
  # networking.dhcpcd.persistent = true;
  # # https://github.com/socallinuxexpo/scale-network/blob/11b15df7c010702b5fd10825003a11cdf98a853a/nix/machines/massflash.nix#L80-L82
  # # Make sure that dhcpcd doesnt timeout when interfaces are down
  # # ref: https://nixos.org/manual/nixos/stable/options.html#opt-networking.dhcpcd.wait
  # networking.dhcpcd.wait = "background";
  # # https://www.reddit.com/r/archlinux/comments/gn090p/dhcpcd_not_responding_to_sigterm_during_reboot_or/
  # # https://bugs.archlinux.org/task/66405
  # systemd.services."dhcpcd".serviceConfig.KillMode = lib.mkForce "process";

  # Increase open file limit for sudoers
  security.pam.loginLimits = [
    {
      domain = "@wheel";
      item = "nofile";
      type = "soft";
      value = "524288";
    }
    {
      domain = "@wheel";
      item = "nofile";
      type = "hard";
      value = "unlimited";
    }
  ];

  environment.variables = {
    "NIXPKGS_SOURCE" = "${inputs.nixpkgs}";
  };

  environment.etc = builtins.listToAttrs (
    map (x: {
      name = "flake-inputs/${x}";
      value = {
        source = inputs."${x}".outPath;
      };
    }) (builtins.attrNames inputs)
  );
}
