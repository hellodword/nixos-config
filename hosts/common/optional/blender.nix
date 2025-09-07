{
  pkgs,
  persistPath,
  userName,
  ...
}:

{
  environment.systemPackages = [ pkgs.blender ];

  environment.persistence = {
    "${persistPath}" = {
      users."${userName}" = {
        directories = [
          ".config/blender"
        ];
      };
    };
  };
}
