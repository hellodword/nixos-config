{
  lib,
  inputs,
  userName,
  ...
}:

{
  imports =
    [
      ../common/global
    ]
    ++ [
      ../common/features/cli

      ../common/features/cli/optional/gpg.nix
      ../common/features/cli/optional/gpg-forwarding.nix
    ];

  home.username = lib.mkDefault "${userName}";

  programs.ssh.matchBlocks = inputs.nixos-privates.ssh."common".matchBlocks;
  programs.gpg.publicKeys = lib.mkAfter inputs.nixos-privates.gpg."r86s".publicKeys;
  services.gpg-agent.sshKeys = lib.mkForce inputs.nixos-privates.gpg."r86s".sshKeys;
  programs.git.aliases."signing" = "!git config commit.gpgsign true && git config tag.gpgsign true && git config user.signingkey ${
    inputs.nixos-privates.gpg."r86s".git-signingkey
  }";

  programs.bash.initExtra = lib.mkAfter ''
    systemctl --failed --quiet --no-pager
    systemctl --user --failed --quiet --no-pager
  '';
}
