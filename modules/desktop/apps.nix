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
    # The application is installed by Home Manager. Its LAN access follows
    # localAccess, while public ports use the host's explicit firewall policy.
    hardware.uinput.enable = lib.mkDefault true;
    nixpkgs.config.allowUnfreePackages = [
      "vscode"
      "vscode-extension-ms-vscode-remote-remote-containers"
      "google-chrome"
    ];
  };
}
