{
  userName,
  persistPath,
  ...
}:

{
  services.safeeyes.enable = true;

  environment.persistence = {
    "${persistPath}" = {
      users."${userName}" = {
        directories = [
          ".config/safeeyes"
        ];
      };
    };
  };
}
