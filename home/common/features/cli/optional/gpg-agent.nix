{ config, ... }:

{
  services.gpg-agent = {
    enable = true;
    enableBashIntegration = config.programs.bash.enable;
    enableSshSupport = config.programs.ssh.enable;
    enableExtraSocket = true;
    extraConfig = '''';
    /*
      gpg --list-keys --with-keygrip | grep -A 1 '\[A'
      ~/.gnupg/sshcontrol
    */
    # sshKeys = inputs.nixos-privates.gpg."<...>".sshKeys;
    verbose = false;
  };
}
