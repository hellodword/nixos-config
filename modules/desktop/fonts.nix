{ pkgs, ... }:
let
  rare = [
    "Jigmo"
    "Jigmo2"
    "Jigmo3"
    "Unifont"
  ];
  symbols = [
    "Noto Sans Symbols"
    "Noto Sans Symbols 2"
  ];
in
{
  fonts = {
    fontDir.enable = true;
    packages = with pkgs; [
      noto-fonts
      noto-fonts-cjk-sans
      noto-fonts-cjk-serif
      noto-fonts-color-emoji
      sarasa-gothic
      nerd-fonts.symbols-only
      jigmo
      unifont
    ];
    fontconfig = {
      antialias = true;
      hinting.style = "slight";
      subpixel.rgba = "none";
      defaultFonts = {
        sansSerif = [
          "Noto Sans"
          "Noto Sans CJK SC"
          "Noto Color Emoji"
          "Symbols Nerd Font"
        ]
        ++ symbols
        ++ rare;
        serif = [
          "Noto Serif"
          "Noto Serif CJK SC"
          "Noto Color Emoji"
          "Symbols Nerd Font"
        ]
        ++ symbols
        ++ rare;
        monospace = [
          "Sarasa Term SC"
          "Noto Color Emoji"
          "Symbols Nerd Font Mono"
        ]
        ++ symbols
        ++ rare;
        emoji = [ "Noto Color Emoji" ];
      };
    };
  };
}
