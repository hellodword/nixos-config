{ pkgs, ... }:

{
  fonts.fontconfig.enable = true;

  xdg.configFile."fontconfig/conf.d" = {
    source = ./conf.d;
    recursive = true;
    force = true;
  };

  me.allowedUnfreePkg = [
    # "corefonts"
    # "vista-fonts"
    # "vista-fonts-chs"
    # "vista-fonts-cht"
  ];

  home.packages = with pkgs; [
    (nerdfonts.override {
      fonts = [
        "JetBrainsMono"
        "RobotoMono"
        "FiraCode"
        "Noto"
        "FiraMono"
        "Terminus"
        "Ubuntu"
        "UbuntuMono"
        "Iosevka"
        "NerdFontsSymbolsOnly"
      ];
    })

    jigmo

    fira-code
    # fira-code-novf
    # fira-code-symbols
    font-awesome

    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-cjk-serif
    # noto-fonts-cjk-novf.sans
    # noto-fonts-cjk-novf.serif

    noto-fonts-emoji
    noto-fonts-emoji-blob-bin
    noto-fonts-extra

    lxgw-wenkai
    lxgw-neoxihei
    lxgw-fusion-kai

    # https://github.com/pmihaly/nix-config/blob/0396f88cf26519659700eea77759e0a9fe4c1132/overlays/default.nix#L27
    (iosevka.override {
      privateBuildPlan = ''
        [buildPlans.iosevka-custom]
        family = "Iosevka Custom"
        spacing = "fontconfig-mono"
        serifs = "slab"
        no-cv-ss = true
        export-glyph-names = true

          [buildPlans.iosevka-custom.ligations]
          inherits = "dlig"

        [buildPlans.iosevka-custom.weights.regular]
        shape = 400
        menu = 400
        css = 400

        [buildPlans.iosevka-custom.weights.bold]
        shape = 700
        menu = 700
        css = 700

        [buildPlans.iosevka-custom.weights.extrabold]
        shape = 800
        menu = 800
        css = 800

        [buildPlans.iosevka-custom.weights.heavy]
        shape = 900
        menu = 900
        css = 900

        [buildPlans.iosevka-custom.slopes.upright]
        angle = 0
        shape = "upright"
        menu = "upright"
        css = "normal"

        [buildPlans.iosevka-custom.slopes.italic]
        angle = 9.4
        shape = "italic"
        menu = "italic"
        css = "italic"
      '';
      set = "custom";
    })

    twemoji-color-font

    harmonyos-sans

    material-design-icons
  ];
}
