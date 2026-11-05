{
  config,
  lib,
  pkgs,
  inputs,
  userName,
  ...
}:
let
  cfg = config.site.cli;
  identityRuntime = "/run/site-identity/${userName}";
  identityPython = pkgs.python3.withPackages (p: [ p.pyyaml ]);
  identityCommand = "${identityPython}/bin/python3 ${../../scripts/secrets}/identity.py";
  runtimeFile =
    description:
    lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      inherit description;
    };
in
{
  imports = [ inputs.nix-index-database.nixosModules.nix-index ];
  options.site.cli = {
    enable = lib.mkEnableOption "native shell and identity configuration";
    identityFile = runtimeFile "Runtime YAML containing public OpenPGP certificates, named subkeys and native SSH/Git configuration.";

  };
  config = lib.mkMerge [
    { programs.nix-index-database.enable = lib.mkDefault cfg.enable; }
    (lib.mkIf cfg.enable {
      nixpkgs.config.allowUnfreePackages = [ "p7zip" ];
      programs.gnupg.agent = {
        enable = true;
        enableSSHSupport = true;
        enableExtraSocket = true;
        pinentryPackage = pkgs.pinentry-qt;
      };
      systemd.services.site-identity = lib.mkIf (cfg.identityFile != null) {
        description = "Publish SSH and Git identities from declared OpenPGP subkeys";
        wantedBy = [ "multi-user.target" ];
        after = [ "sops-install-secrets.service" ];
        path = [ pkgs.gnupg ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${identityCommand} prepare --source ${lib.escapeShellArg cfg.identityFile} --runtime ${identityRuntime} --user ${lib.escapeShellArg userName}";
          RuntimeDirectory = "site-identity/${userName}";
          RuntimeDirectoryMode = "0755";
          RuntimeDirectoryPreserve = "yes";
          UMask = "0077";
          NoNewPrivileges = true;
          PrivateTmp = true;
          PrivateDevices = true;
          ProtectHome = true;
          ProtectSystem = "strict";
          ReadWritePaths = [ "/etc/ssh" ];
          RestrictAddressFamilies = [ "AF_UNIX" ];
        };
      };
      programs.nix-index.enable = true;
      programs.nix-index-database.comma.enable = true;
      systemd.user.tmpfiles.rules = [ "d %h/.ssh/hosts.d 0700 - - -" ];
    })
  ];
}
