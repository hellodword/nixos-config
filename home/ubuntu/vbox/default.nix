{ inputs, lib, ... }:

{
  imports = [
    ../global
    ../features/cli
  ]
  ++
  [
    ../features/desktop/i3
  ]
  ;

  home.username = lib.mkDefault "ubuntu";

  /*
    # in nixos-privates
    monitors = {
      "vbox-embedded" = {
        name = "Virtual-1";
        fingerprint = "--CONNECTED-BUT-EDID-UNAVAILABLE--Virtual-1";
        mode = "1440x900";
      };
  */

  programs.autorandr = {
    enable = true;
    profiles = {
      default = {
        fingerprint = {
          "${inputs.nixos-privates.monitors."vbox-embedded".name}" = "${inputs.nixos-privates.monitors."vbox-embedded".fingerprint}";
        };
        config = {
          "${inputs.nixos-privates.monitors."vbox-embedded".name}" = {
            enable = true;
            primary = true;
            position = "0x0";
            mode = "${inputs.nixos-privates.monitors."vbox-embedded".mode}";
            rate = "60.00";
          };
        };
      };
    };
  };
}
