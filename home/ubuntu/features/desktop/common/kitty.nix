{ lib, inputs, pkgs, ... }:

{
  # ~~滚动条~~ https://github.com/kovidgoyal/kitty/issues/2502#issuecomment-606996263
  # WARNING: terminal is not fully functional https://sw.kovidgoyal.net/kitty/faq/#i-get-errors-about-the-terminal-being-unknown-or-opening-the-terminal-failing-or-functional-keys-like-arrow-keys-don-t-work
  programs.kitty = {
    enable = true;
    package = pkgs.kitty;
    font = {
      name = "FiraCode Nerd Font";
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
      symbol_map U+4E00–U+9FFF Noto Serif CJK SC
      modify_font underline_position +3
      modify_font underline_thickness 150%

      ${builtins.readFile (inputs.kitty-gruvbox-themes + "/gruvbox_dark.conf")}
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
