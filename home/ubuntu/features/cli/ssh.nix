{ config, persistPath, ... }:

{
  # https://serverfault.com/questions/581367/amazon-ec2-instance-ssh-rsa-fingerprint/581458#581458
  # https://blog.stribik.technology/2015/01/04/secure-secure-shell.html

  # services.ssh-agent.enable = true;

  # home.packages = with pkgs; [
  #   x11_ssh_askpass
  # ];

  # home.sessionVariables.SSH_ASKPASS = "${pkgs.x11_ssh_askpass}/libexec/x11-ssh-askpass";
  # home.sessionVariables.SSH_ASKPASS_REQUIRE = "prefer";

  programs.ssh = {
    enable = true;
    hashKnownHosts = true;
    serverAliveCountMax = 60;
    serverAliveInterval = 30;
    # extraConfig = ''
    #   AddKeysToAgent=yes
    # '';
  };

  home.persistence = {
    "${persistPath}${config.home.homeDirectory}".directories = [ ".ssh" ];
  };
}
