{
  pkgs,
  lib,
  config,
  ...
}:

{
  home.packages = with pkgs; [
    libnotify
  ];

  services.mako = {
    enable = true;
    settings = {
      anchor = "top-right";
      default-timeout = 3000;
      font = "monospace 10";
      on-button-left = "invoke-default-action";
      on-button-middle = "exec makoctl menu -n \"$id\" ${lib.getExe config.programs.rofi.package} -dmenu -p 'Select action: '";
      on-button-right = "dismiss";
      "urgency=high" = {
        border-color = "#fab387";
        font = "monospace 12";
        width = 400;
        height = 150;
        text-color = "#ff6100";
      };
    };
  };
}
