{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:
{
  imports = [
    (modulesPath + "/profiles/minimal.nix")
    (modulesPath + "/profiles/qemu-guest.nix")
  ];
  system.stateVersion = "26.05";
  networking.useNetworkd = true;
  networking.useDHCP = false;
  networking.usePredictableInterfaceNames = false;
  networking.nftables.enable = true;
  networking.firewall.enable = true;
  services.resolved = {
    enable = true;
    settings.Resolve = {
      DNSOverTLS = "yes";
      Cache = true;
      FallbackDNS = [ ];
      LLMNR = false;
      MulticastDNS = false;
    };
  };
  services.chrony = {
    enable = true;
    enableNTS = true;
    servers = import ../../lib/nts-servers.nix;
  };
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
    hostKeys = [
      {
        path = "/etc/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }
    ];
  };
  systemd.services.sshd-keygen.serviceConfig.StandardOutput = "journal+console";
  boot.tmp.useTmpfs = false;
  boot.kernelParams = [
    "console=tty0"
    "console=ttyS0,115200n8"
  ];
  boot.kernel.sysctl."vm.swappiness" = 20;
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    max-jobs = 1;
    cores = 1;
  };
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };
  services.journald.settings.Journal = {
    SystemMaxUse = "128M";
    RuntimeMaxUse = "32M";
    MaxRetentionSec = "7day";
  };
  environment.systemPackages = [
    pkgs.curl
    pkgs.jq
  ];
}
