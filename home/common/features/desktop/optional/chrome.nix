{
  lib,
  config,
  persistPath,
  pkgs,
  ...
}:

{
  me.allowedUnfreePkg = [ pkgs.google-chrome ];

  home.persistence = {
    "${persistPath}".directories = [ ".config/google-chrome" ];
  };

  me.exitProcess = [
    "chrome"
  ];

  programs."google-chrome" = {
    enable = true;
    commandLineArgs = [
      # https://github.com/violentmonkey/violentmonkey/issues/2284#issuecomment-3425714429
      "--disable-features=ExtensionManifestV2Unsupported,ExtensionManifestV2Disabled"
    ];
    # https://github.com/nix-community/home-manager/blob/d1f04b0f365a34896a37d9015637796537ec88a3/modules/programs/chromium.nix#L184
  };

  # flutter debugger or other apps need this
  home.sessionVariables.CHROME_EXECUTABLE = lib.mkOverride 1000 "${
    config.programs."google-chrome".package
  }/bin/google-chrome-stable";
}
