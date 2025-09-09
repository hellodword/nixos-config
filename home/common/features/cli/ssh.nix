{ ... }:

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
    enableDefaultConfig = false;
    matchBlocks."*" = {
      hashKnownHosts = true;
      serverAliveCountMax = 60;
      serverAliveInterval = 30;
      identitiesOnly = true;
      extraOptions = {
        ForwardAgent = "no";
        AddKeysToAgent = "no";
        Compression = "no";
        UserKnownHostsFile = "~/.ssh/known_hosts";
        ControlMaster = "no";
        ControlPath = "~/.ssh/master-%r@%n:%p";
        ControlPersist = "no";
      };
    };
  };

  programs.bash.shellAliases = {
    "ssh-passwordonly" = "ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password";
    "ssh-skip-checking" = "ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no";
  };
}
