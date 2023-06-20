{ pkgs, ... }:

{
  nixpkgs = {
    config = {
      permittedInsecurePackages = [
        # goldendict
        "qtwebkit-5.212.0-alpha4"
      ];
    };
  };

  home.packages = with pkgs; [
    goldendict
  ];

  # TODO persist
}
