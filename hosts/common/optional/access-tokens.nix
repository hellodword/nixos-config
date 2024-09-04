{ config, ... }:

{
  # https://nixos.org/manual/nix/stable/command-ref/conf-file.html
  # https://github.com/Minion3665/NixFiles/blob/fbac178eed89a8bef2e9f8ecded76b0a2d438355/modules/tokens.nix

  /*
    Other files can be included with a line like include path,
    where path is interpreted relative to the current conf file
    and a missing file is an error unless !include is used instead
  */
  nix.extraOptions = ''
    !include ${config.sops.secrets."access-tokens".path}
  '';

  # access-tokens: "access-tokens = github.com=123456 gitlab.sample.com=PAT:123456"
  sops.secrets."access-tokens" = {
    mode = "0440";
    sopsFile = ../../${config.networking.hostName}/secrets/secrets.yaml;
    neededForUsers = true;
  };
}
