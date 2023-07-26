{ config, persistPath, ... }:

{
  # TODO
  services.gpg-agent = {
    enable = true;
    enableBashIntegration = config.programs.bash.enable;
    enableExtraSocket = false;
    enableScDaemon = true;
    enableSshSupport = config.programs.ssh.enable;
    extraConfig = '''';
    sshKeys = null;
    verbose = false;
  };

  programs.gpg = {
    enable = true;
    homedir = "${config.home.homeDirectory}/.gnupg";
    mutableKeys = true;
    mutableTrust = true;
    publicKeys = [ ];
    scdaemonSettings = { };
    settings = { };
  };

  home.persistence = {
    "${persistPath}${config.home.homeDirectory}".directories = [ ".gnupg" ];
  };
}
