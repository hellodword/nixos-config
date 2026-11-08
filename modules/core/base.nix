{
  config,
  lib,
  pkgs,
  inputs,
  userName,
  ...
}:
let
  cfg = config.site.core;
in
{
  imports = [
    inputs.impermanence.nixosModules.impermanence
    inputs.sops-nix.nixosModules.sops
  ];
  options.site.core.enable = lib.mkEnableOption "persistent, secure laptop base";
  config = lib.mkIf cfg.enable {
    system.configurationRevision = inputs.self.rev or (inputs.self.dirtyRev or "uncommitted");
    environment.etc."flake-inputs/self".source = inputs.self.outPath;
    users.mutableUsers = false;
    users.users.${userName} = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
    };
    sops = {
      age = {
        keyFile = "${config.site.storage.persistRoot}/var/lib/sops-nix/keys.txt";
        generateKey = false;
        sshKeyPaths = [ ];
      };
      gnupg.sshKeyPaths = [ ];
    };
    security.sudo.enable = false;
    security.sudo-rs = {
      enable = true;
      wheelNeedsPassword = true;
    };
    networking.firewall.enable = true;
    services.openssh = {
      enable = lib.mkDefault false;
      settings = {
        PermitRootLogin = "no";
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
      };
    };
    boot.kernel.sysctl = {
      "kernel.sysrq" = 176;
      "kernel.io_uring_disabled" = 1;
    };
    services.journald.settings.Journal = {
      Storage = "persistent";
      SystemMaxUse = "512M";
      SystemMaxFileSize = "32M";
      MaxRetentionSec = "14day";
    };
    programs.ssh.knownHostsFiles = [ ../../data/ssh_known_hosts ];
    boot.tmp = {
      useTmpfs = true;
      tmpfsSize = "80%";
    };
    systemd.services.nix-daemon.environment.TMPDIR = "/var/cache/nix";
    systemd.tmpfiles.rules = [ "d /var/cache/nix 1777 root root -" ];
    nix = {
      registry.nixpkgs.flake = inputs.nixpkgs;
      nixPath = [ "nixpkgs=${inputs.nixpkgs}" ];
      settings = {
        experimental-features = [
          "nix-command"
          "flakes"
        ];
        auto-optimise-store = true;
        sandbox = true;
        require-sigs = true;
        trusted-users = [ "root" ];
      };
      gc = {
        automatic = true;
        dates = "weekly";
        options = "--delete-older-than 30d";
        persistent = true;
        randomizedDelaySec = "45m";
      };
    };
    i18n.defaultLocale = "en_US.UTF-8";
    i18n.supportedLocales = [
      "en_US.UTF-8/UTF-8"
      "zh_CN.UTF-8/UTF-8"
    ];
    time.timeZone = lib.mkDefault "UTC";
    services.timesyncd = {
      enable = true;
      servers = [
        "ntp.aliyun.com"
        "time.cloudflare.com"
      ];
    };
    environment.systemPackages = with pkgs; [
      vim
      git
      jq
      file
      tree
      unzip
      lsof
      ncdu
      rsync
      strace
      htop
      pciutils
      lm_sensors
      sops
      openssl_legacy
      nix-output-monitor
      nix-tree
      nixfmt
      nixd
      just
    ];
    systemd.suppressedSystemUnits = [ "systemd-machine-id-commit.service" ];
    programs.fuse.userAllowOther = true;
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
  };
}
