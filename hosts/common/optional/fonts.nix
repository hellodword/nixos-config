{ pkgs, ... }:

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
      nerd-fonts.jetbrains-mono
      nerd-fonts.noto
      nerd-fonts.symbols-only

      jigmo

      noto-fonts-color-emoji

      noto-fonts
      noto-fonts-cjk-sans
      noto-fonts-cjk-serif

      unifont
      # # https://www.babelstone.co.uk/Fonts/Han.html
      # babelstone-han
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
          serif =
            [ ]
            # 使用 Symbols Nerd Font 专门处理图标
            ++ [ "Symbols Nerd Font" ]
            # 西文优先
            ++ [ "Noto Serif" ]
            # 中文优先
            ++ [ "Noto Serif CJK SC" ]
            # 放在 CJK 之后是为了防止数字和通用标点变成 Emoji 图片，但必须放在生僻字和符号字体之前
            ++ emoji
            # 符号兜底：Noto Sans Symbols
            ++ [
              "Noto Sans Symbols"
              "Noto Sans Symbols 2"
            ]
            # CJK 生僻字兜底
            ++ jigmo;

          sansSerif =
            [ ]
            # 使用 Symbols Nerd Font 专门处理图标，不影响文字
            ++ [ "Symbols Nerd Font" ]
            # 西文优先
            ++ [ "Noto Sans" ]
            # 中文优先
            ++ [ "Noto Sans CJK SC" ]
            # 放在 CJK 之后是为了防止数字和通用标点变成 Emoji 图片，但必须放在生僻字和符号字体之前
            ++ emoji
            # 符号兜底：Noto Sans Symbols
            ++ [
              "Noto Sans Symbols"
              "Noto Sans Symbols 2"
            ]
            # CJK 生僻字兜底
            ++ jigmo
            # 最后的最后：Unifont (以此确保不出现方块，雖然很难看)
            ++ [ "Unifont" ];

          monospace =
            [ ]
            # 注意：等宽环境推荐用 Mono 版本的 Nerd Symbols，以保持对齐
            ++ [ "Symbols Nerd Font Mono" ]
            # Noto Sans Mono 包含 Powerline 符号，但不包含全部 Nerd 图标
            ++ [ "Noto Sans Mono" ]
            # 中文优先
            ++ [ "Noto Sans Mono CJK SC" ]
            # 放在 CJK 之后是为了防止数字和通用标点变成 Emoji 图片，但必须放在生僻字和符号字体之前
            ++ emoji
            # 符号兜底：Noto Sans Symbols
            ++ [
              "Noto Sans Symbols"
              "Noto Sans Symbols 2"
            ]
            # CJK 生僻字兜底
            ++ jigmo;

          emoji = emoji;
        };
      };
  };
}
