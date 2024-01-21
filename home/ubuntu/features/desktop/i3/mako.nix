{ pkgs, lib, config, ... }:

{
  home.packages = with pkgs; [
    libnotify
  ];

  services.mako = {
    enable = true;
    anchor = "top-right";
    # backgroundColor = "#285577FF";
    defaultTimeout = 3000;
    font = "monospace 10";
    extraConfig = ''
      on-button-left=invoke-default-action
      on-button-middle=exec makoctl menu -n "$id" ${lib.getExe config.programs.rofi.package} -dmenu -p 'Select action: '
      on-button-right=dismiss

      [urgency=high]
      border-color=#fab387
      font=monospace 12
      width=400
      height=150
      text-color=#ff6100
    '';
  };
}
