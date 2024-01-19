{ pkgs, ... }:

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
      [urgency=high]
      border-color=#fab387
      font=monospace 12
      width=400
      height=150
      text-color=#ff6100
    '';
  };
}
