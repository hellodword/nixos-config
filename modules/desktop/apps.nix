{
  config,
  lib,
  ...
}:
{
  options.site.apps.enable = lib.mkEnableOption "browser, communication and container-focused editor";
  config = lib.mkIf config.site.apps.enable {
    programs.firejail.enable = true;
    programs.chromium = {
      enable = true;
      extraOpts.DnsOverHttpsMode = "off";
    };
    programs.kdeconnect.enable = true;
    nixpkgs.config.allowUnfreePackages = [
      "vscode"
      "vscode-extension-ms-vscode-remote-remote-containers"
      "google-chrome"
    ];
  };
}
