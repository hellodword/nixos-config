{ lib, ... }:

{
  programs.bash.initExtra = lib.mkAfter ''
    gpgconf --create-socketdir
  '';

  home.sessionVariables.SSH_AUTH_SOCK = "/run/user/1000/gnupg/S.gpg-agent.ssh";
}
