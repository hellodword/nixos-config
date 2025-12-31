{
  config,
  lib,
  userName,
  ...
}:

{
  users.mutableUsers = false;
  users.users."${userName}" = {
    isNormalUser = true;
    uid = 1000;
    extraGroups = [ "wheel" ];
  };

  services.openssh.settings.PermitRootLogin = lib.mkForce "no";

  services.openssh.settings.PasswordAuthentication =
    if
      builtins.length config.users.users."${userName}".openssh.authorizedKeys.keyFiles == 0
      && builtins.length config.users.users."${userName}".openssh.authorizedKeys.keys == 0
    then
      true
    else
      false;
}
