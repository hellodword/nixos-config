{
  pkgs,
  persistPath,
  userName,
  ...
}:

{
  environment.systemPackages = with pkgs; [
    libreoffice
  ];

  environment.persistence = {
    "${persistPath}" = {
      users."${userName}" = {
        directories = [
          ".config/libreoffice"
        ];
      };
    };
  };
}
