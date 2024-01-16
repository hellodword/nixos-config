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
  };
}
