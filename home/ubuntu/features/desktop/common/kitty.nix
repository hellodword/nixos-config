{ lib, inputs, pkgs, ... }:

{
  # ~~滚动条~~ https://github.com/kovidgoyal/kitty/issues/2502#issuecomment-606996263
  # WARNING: terminal is not fully functional https://sw.kovidgoyal.net/kitty/faq/#i-get-errors-about-the-terminal-being-unknown-or-opening-the-terminal-failing-or-functional-keys-like-arrow-keys-don-t-work
  programs.kitty = {
    enable = true;
    package = pkgs.kitty;
    font = {
      name = "monospace";
      size = 11.0;
    };
    # theme = "Catppuccin-Macchiato";
    settings = {
      # term = "xterm-256color";
      tab_fade = "1 1 1";
      tab_title_template =
        "{fmt.fg.red}{bell_symbol}{activity_symbol}{fmt.fg.tab}{index}:{title}";
    };
    extraConfig = ''
      # https://stackoverflow.com/a/1366113
      # But
      # https://github.com/kovidgoyal/kitty/issues/6572#issuecomment-1690889330
      # symbol_map U+4E00-U+9FFF LXGW WenKai
      # symbol_map U+3400-U+4DBF LXGW WenKai

      # symbol_map U+F900-U+FAFF Jigmo

      # symbol_map U+20000-U+2A6DF Jigmo2
      # symbol_map U+2A700-U+2B73F Jigmo2
      # symbol_map U+2B740-U+2B81F Jigmo2
      # symbol_map U+2B820-U+2CEAF Jigmo2
      # symbol_map U+2CEB0-U+2EBEF Jigmo2
      # symbol_map U+2EBF0-U+2EE5F Jigmo2

      # symbol_map U+30000-U+3134F Jigmo3
      # symbol_map U+31350-U+323AF Jigmo3

      # modify_font underline_position +3
      # modify_font underline_thickness 150%

      include ${inputs.catppuccin-kitty}/themes/mocha.conf
    '';
    keybindings = {
      "kitty_mod+n" = "new_os_window_with_cwd";
      "kitty_mod+t" = "new_tab_with_cwd";
    };
  };

  programs.ssh.extraConfig = lib.mkAfter ''
    SetEnv TERM=xterm-color
  '';
  # programs.ssh.extraOptionOverrides = {
  #   SetEnv = "TERM=xterm-color";
  # };
}
