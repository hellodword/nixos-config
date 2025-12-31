{ userName, ... }:

{
  users.users."${userName}".extraGroups = [ "video" ];

  hardware.brillo.enable = true;
  programs.light.enable = true;
}
