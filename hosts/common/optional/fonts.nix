{ pkgs, lib, ... }:

{
  me.allowedUnfreePkg = [
    # "corefonts"
    # "vista-fonts"
    # "vista-fonts-chs"
    # "vista-fonts-cht"
  ];

  fonts = {
    # enableDefaultFonts = false;
    fontDir.enable = true;
    packages = with pkgs; [
      (nerdfonts.override {
        fonts = [
          "JetBrainsMono"
          # "RobotoMono"
          # "FiraCode"
          "Noto"
          # "FiraMono"
          # "Terminus"
          # "Ubuntu"
          # "UbuntuMono"
          # "Iosevka"
          "NerdFontsSymbolsOnly"
        ];
      })

      jigmo

      # roboto
      # roboto-slab
      # sarasa-gothic

      # corefonts
      # fira-code
      # fira-code-novf
      # fira-code-symbols
      # font-awesome
      # hanazono
      # # hoyo-glyphs
      # liberation_ttf

      noto-fonts
      noto-fonts-cjk-sans
      noto-fonts-cjk-serif
      # noto-fonts-cjk-novf.sans
      # noto-fonts-cjk-novf.serif

      noto-fonts-emoji
      noto-fonts-emoji-blob-bin
      noto-fonts-extra
      # plangothic-fonts.allideo
      # source-code-pro
      # source-han-code-jp
      # source-han-mono
      # source-han-sans
      # source-han-serif
      # source-sans
      # source-sans-pro
      # source-serif
      # source-serif-pro
      # terminus_font_ttf
      # ubuntu_font_family
      # vistafonts
      # vistafonts-chs
      # vistafonts-cht
      # wqy_microhei
      # wqy_zenhei

      lxgw-wenkai
      lxgw-neoxihei
      lxgw-fusion-kai

      # rubik
      # # https://github.com/pmihaly/nix-config/blob/0396f88cf26519659700eea77759e0a9fe4c1132/overlays/default.nix#L27
      # (iosevka.override {
      #   privateBuildPlan = ''
      #     [buildPlans.iosevka-custom]
      #     family = "Iosevka Custom"
      #     spacing = "fontconfig-mono"
      #     serifs = "slab"
      #     no-cv-ss = true
      #     export-glyph-names = true

      #       [buildPlans.iosevka-custom.ligations]
      #       inherits = "dlig"

      #     [buildPlans.iosevka-custom.weights.regular]
      #     shape = 400
      #     menu = 400
      #     css = 400

      #     [buildPlans.iosevka-custom.weights.bold]
      #     shape = 700
      #     menu = 700
      #     css = 700

      #     [buildPlans.iosevka-custom.weights.extrabold]
      #     shape = 800
      #     menu = 800
      #     css = 800

      #     [buildPlans.iosevka-custom.weights.heavy]
      #     shape = 900
      #     menu = 900
      #     css = 900

      #     [buildPlans.iosevka-custom.slopes.upright]
      #     angle = 0
      #     shape = "upright"
      #     menu = "upright"
      #     css = "normal"

      #     [buildPlans.iosevka-custom.slopes.italic]
      #     angle = 9.4
      #     shape = "italic"
      #     menu = "italic"
      #     css = "italic"
      #   '';
      #   set = "custom";
      # })

      # twemoji-color-font

      # harmonyos-sans

      # material-design-icons

      # jetbrains-mono
      # cascadia-code
    ];

    fontconfig =
      let
        jigmo = [
          "Jigmo"
          "Jigmo2"
          "Jigmo3"
        ];
        emoji = [
          "Noto Color Emoji"
        ];
      in
      {
        defaultFonts = {
          serif = [ "NotoSerif Nerd Font" ] ++ emoji ++ [ "LXGW Neo XiHei" ] ++ jigmo;
          sansSerif = [ "NotoSans Nerd Font" ] ++ emoji ++ [ "LXGW WenKai" ] ++ jigmo;
          monospace = [ "NotoMono Nerd Font" ] ++ emoji ++ [ "LXGW WenKai" ] ++ jigmo;
          emoji = emoji;
        };
      };
  };
}
