{ config, persistPath, ... }:

{
  # https://serverfault.com/questions/581367/amazon-ec2-instance-ssh-rsa-fingerprint/581458#581458
  # https://blog.stribik.technology/2015/01/04/secure-secure-shell.html

  programs.ssh = {
    enable = true;
    hashKnownHosts = true;
    serverAliveCountMax = 60;
    serverAliveInterval = 30;
    # for kitty
    extraConfig = ''
      SetEnv=TERM=xterm-color
    '';
    extraOptionOverrides = {
      SetEnv = "TERM=xterm-color";
    };
  };

  home.persistence = {
    "${persistPath}${config.home.homeDirectory}".directories = [ ".ssh" ];
  };
}
