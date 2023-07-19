{ lib, inputs, pkgs, ... }:

{
  imports = [
    ../global
    ../features/cli
  ]
  ++
  [
    ../features/desktop/i3
    ../features/desktop/optional/flameshot.nix

    ../features/cli/optional/bat.nix
    ../features/cli/optional/nix-index.nix

    ../features/desktop/optional/kdeconnect.nix
    ../features/desktop/optional/safeeyes.nix

    ../features/desktop/optional/peek.nix

    ../features/desktop/optional/firefox.nix
    ../features/desktop/optional/chromium.nix
    ../features/desktop/optional/chrome.nix
    ../features/desktop/optional/vscode.nix
    ../features/desktop/optional/thunderbird.nix
    ../features/desktop/optional/joplin.nix
    ../features/desktop/optional/bitwarden.nix
    ../features/desktop/optional/libreoffice.nix
    ../features/desktop/optional/virtualbox.nix
    ../features/desktop/optional/android-studio.nix

    ../features/dev/optional/go.nix
  ]
  ;

  home.username = lib.mkDefault "ubuntu";

  programs.ssh.matchBlocks = inputs.nixos-privates.ssh."laptop".matchBlocks;
  programs.firefox.profiles.default.bookmarks = inputs.nixos-privates.firefox."laptop".bookmarks;

  programs.autorandr = {
    enable = true;
    profiles = {
      default = {
        fingerprint = {
          "${inputs.nixos-privates.monitors."laptop3-embedded".name}" = "${inputs.nixos-privates.monitors."laptop3-embedded".fingerprint}";
        };
        config = {
          "${inputs.nixos-privates.monitors."laptop3-embedded".name}" = {
            enable = true;
            primary = true;
            position = "0x0";
            mode = "${inputs.nixos-privates.monitors."laptop3-embedded".mode}";
            rate = "60.00";
          };
        };
      };
      "with-dell-1" = {
        fingerprint = {
          "${inputs.nixos-privates.monitors."laptop3-embedded".name}" = "${inputs.nixos-privates.monitors."laptop3-embedded".fingerprint}";
          "${inputs.nixos-privates.monitors."dell-1".name}" = "${inputs.nixos-privates.monitors."dell-1".fingerprint}";
        };
        config = {
          "${inputs.nixos-privates.monitors."laptop3-embedded".name}" = {
            enable = false;
            primary = false;
            position = "0x0";
            mode = "${inputs.nixos-privates.monitors."laptop3-embedded".mode}";
            rate = "60.00";
          };
          "${inputs.nixos-privates.monitors."dell-1".name}" = {
            enable = true;
            primary = true;
            position = "0x0";
            mode = "${inputs.nixos-privates.monitors."dell-1".mode}";
            rate = "60.00";
          };
        };
      };
    };
    hooks = {
      postswitch = {
        "change-dpi" = ''
          case "$AUTORANDR_CURRENT_PROFILE" in
            default)
              DPI=120
              ;;
            with-dell-1)
              DPI=110
              ;;
            *)
              echo "Unknown profile: $AUTORANDR_CURRENT_PROFILE"
              exit 1
          esac

          echo "Xft.dpi: $DPI" | ${pkgs.xorg.xrdb}/bin/xrdb -merge
        '';
      };
    };
  };

  # programs.alacritty.settings.font.size = lib.mkForce 9.0;
  # programs.kitty.font.size = lib.mkForce 9.0;
}
