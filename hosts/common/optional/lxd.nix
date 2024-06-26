{ lib, config, persistPath, userName, ... }:

{
  # https://jnsgr.uk/2024/06/desktop-vms-lxd-multipass/
  # https://discourse.nixos.org/t/howto-setup-lxd-on-nixos-with-nixos-guest-using-unmanaged-bridge-network-interface/21591/1

  users = {
    users.${userName}.extraGroups = [ "lxd" ];
  };

  virtualisation = {
    lxd = {
      enable = true;

      # This turns on a few sysctl settings that the LXD documentation recommends
      # for running in production.
      recommendedSysctlSettings = true;

      ui = {
        enable = true;
      };
    };
  };

  # This enables lxcfs, which is a FUSE fs that sets up some things so that
  # things like /proc and cgroups work better in lxd containers.
  # See https://linuxcontainers.org/lxcfs/introduction/ for more info.
  #
  # Also note that the lxcfs NixOS option says that in order to make use of
  # lxcfs in the container, you need to include the following NixOS setting
  # in the NixOS container guest configuration:
  #
  # virtualisation.lxc.defaultConfig = "lxc.include = ''${pkgs.lxcfs}/share/lxc/config/common.conf.d/00-lxcfs.conf";
  virtualisation.lxc.lxcfs.enable = true;

  # This sets up a bridge called "mylxdbr0".  This is used to provide NAT'd
  # internet to the guest.  This bridge is manipulated directly by lxd, so we
  # don't need to specify any bridged interfaces here.
  networking.bridges = { mylxdbr0.interfaces = [ ]; };

  # Add an IP address to the bridge interface.
  networking.localCommands = ''
    ip address add 192.168.57.1/24 dev mylxdbr0
  '';

  # Firewall commands allowing traffic to go in and out of the bridge interface
  # (and to the guest LXD instance).  Also sets up the actual NAT masquerade rule.
  networking.firewall.extraCommands = ''
    iptables -A INPUT -i mylxdbr0 -m comment --comment "my rule for LXD network mylxdbr0" -j ACCEPT

    # These three technically aren't needed, since by default the FORWARD and
    # OUTPUT firewalls accept everything everything, but lets keep them in just
    # in case.
    iptables -A FORWARD -o mylxdbr0 -m comment --comment "my rule for LXD network mylxdbr0" -j ACCEPT
    iptables -A FORWARD -i mylxdbr0 -m comment --comment "my rule for LXD network mylxdbr0" -j ACCEPT
    iptables -A OUTPUT -o mylxdbr0 -m comment --comment "my rule for LXD network mylxdbr0" -j ACCEPT

    iptables -t nat -A POSTROUTING -s 192.168.57.0/24 ! -d 192.168.57.0/24 -m comment --comment "my rule for LXD network mylxdbr0" -j MASQUERADE
  '';

  # ip forwarding is needed for NAT'ing to work.
  boot.kernel.sysctl = {
    "net.ipv4.conf.all.forwarding" = true;
    "net.ipv4.conf.default.forwarding" = true;
  };

  # kernel module for forwarding to work
  boot.kernelModules = [ "nf_nat_ftp" ];

  systemd.services.lxd.after = lib.optionals (builtins.hasAttr "sing-box" config.systemd.services) [ "sing-box.service" ];

  environment.persistence = {
    "${persistPath}".directories = [
      "/var/lib/lxd"
      "/var/lib/lxc"
    ];
  };
}
