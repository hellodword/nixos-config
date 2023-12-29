{ lib, inputs, ... }:

{
  imports = [
    ../global
  ]
  ++
  [
    ../features/cli

    ../features/cli/optional/gpg.nix
    ../features/cli/optional/gpg-forwarding.nix
  ]
  ;

  home.username = lib.mkDefault "ubuntu";

  programs.ssh.matchBlocks = inputs.nixos-privates.ssh."common".matchBlocks;
  programs.gpg.publicKeys = lib.mkAfter inputs.nixos-privates.gpg."r86s".publicKeys;
  services.gpg-agent.sshKeys = lib.mkForce inputs.nixos-privates.gpg."r86s".sshKeys;
  programs.git.aliases."signing" = "!git config commit.gpgsign true && git config tag.gpgsign true && git config user.signingkey ${inputs.nixos-privates.gpg."r86s".git-signingkey}";
}
