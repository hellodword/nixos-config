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
    # sshKeys = inputs.privates.gpg."<...>".sshKeys;
    verbose = false;
    # https://github.com/nix-community/home-manager/issues/4804#issuecomment-1871272189
    pinentryFlavor = "qt";
  };
}
