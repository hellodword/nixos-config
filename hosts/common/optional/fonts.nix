# https://github.com/GTrunSec/hive/blob/37b3bb48973ab792b3ead93a8604e663093eae1e/cells/guangtao/nixosModules/fonts.nix
{ pkgs, ... }:

{
  # fonts = {
  #   enableDefaultFonts = true;
  #   fonts = with pkgs;
  #     [
  #       fantasque-sans-mono
  #       noto-fonts
  #       noto-fonts-cjk-sans
  #       noto-fonts-cjk-serif
  #       noto-fonts-emoji
  #       emojione
  #       twemoji-color-font
  #       siji
  #       unifont
  #       unifont_upper
  #       liberation_ttf
  #       fira-code
  #       fira-code-symbols
  #       dina-font
  #       proggyfonts
  #       source-han-sans-simplified-chinese
  #       source-han-sans-traditional-chinese
  #       material-icons
  #       weather-icons
  #       iosevka
  #       (nerdfonts.override { fonts = [ "JetBrainsMono" "RobotoMono" "FiraCode" ]; })
  #     ]
  #     ++ [
  #       material-symbols
  #     ];

  #   fontconfig = {
  #     defaultFonts = {
  #       serif = [ "FantasqueSansMono Nerd Font Mono" "Weibei SC" ];
  #       sansSerif = [ "FantasqueSansMono Nerd Font Mono" "Weibei SC" ];
  #       monospace = [ "FantasqueSansMono Nerd Font Mono" ];
  #     };
  #   };
  # };

  # https://github.com/alacritty/alacritty/issues/153

  fonts = {
    # enableDefaultFonts = false;
    fontDir.enable = true;
    packages = with pkgs; [
      noto-fonts
      noto-fonts-cjk-sans
      noto-fonts-cjk-serif
      noto-fonts-emoji
      jetbrains-mono
      roboto
      roboto-slab
      sarasa-gothic
      (nerdfonts.override { fonts = [ "JetBrainsMono" "RobotoMono" "FiraCode" "Noto" ]; })
    ];
    # fontconfig.defaultFonts = pkgs.lib.mkForce {
    #   serif = [
    #     "Noto Serif"
    #     "Noto Serif CJK SC"
    #     "Noto Color Emoji"
    #   ];
    #   sansSerif = [
    #     "Noto Sans"
    #     "Noto Sans CJK SC"
    #     "Noto Color Emoji"
    #   ];
    #   monospace = [
    #     "JetBrains Mono"
    #     "Noto Color Emoji"
    #   ];
    #   emoji = [
    #     "Noto Color Emoji"
    #   ];
    # };
    fontconfig.defaultFonts = {
      monospace = [ "RobotoMono Nerd Font" "Noto Sans Mono CJK SC" ];
      sansSerif = [ "Roboto" "Sarasa Gothic SC" "NotoSans Nerd Font" ];
      serif = [ "Roboto Slab" "Noto Serif CJK SC" "NotoSerif Nerd Font" ];
      emoji = [ "Noto Color Emoji" ];
    };
  };
}
