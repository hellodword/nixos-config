{
  pkgs,
  persistPath,
  userName,
  ...
}:

{
  environment.systemPackages = with pkgs; [
    remmina
  ];

  environment.persistence = {
    "${persistPath}" = {
      users."${userName}" = {
        directories = [
          ".config/remmina"
          ".local/share/remmina"
          ".config/freerdp"
        ];
      };
    };
  };
}
