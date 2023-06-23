{ pkgs, ... }:

{
  home.pointerCursor = {
    package = pkgs.phinger-cursors;
    name = "phinger-cursors-light";
    # Make cursor not tiny on HiDPI screens
    # size = 128;
    x11.enable = true;
  };
}
