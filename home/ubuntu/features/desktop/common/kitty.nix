{ pkgs, ... }:

{
  # ~~滚动条~~ https://github.com/kovidgoyal/kitty/issues/2502#issuecomment-606996263
  programs.kitty = {
    enable = true;
    package = pkgs.kitty;
    font = {
      name = "FiraCode Nerd Font";
      size = 11.0;
    };
    theme = "Catppuccin-Macchiato";
    settings = {
      # term = "xterm-256color";
      tab_fade = "1 1 1";
      tab_title_template =
        "{fmt.fg.red}{bell_symbol}{activity_symbol}{fmt.fg.tab}{index}:{title}";
    };
    extraConfig = ''
      symbol_map U+4E00–U+9FFF Noto Serif CJK SC
      modify_font underline_position +3
      modify_font underline_thickness 150%
    '';
    keybindings = {
      "kitty_mod+n" = "new_os_window_with_cwd";
      "kitty_mod+t" = "new_tab_with_cwd";
    };
  };
}
