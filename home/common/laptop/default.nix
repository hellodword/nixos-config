{ lib, inputs, pkgs, nixosConfig, userName, ... }:

let
  X = nixosConfig.services.xserver.windowManager.i3.enable;
in
{
  imports = [
    ../global
  ]
  ++
  [
    ../features/cli

    ../features/cli/optional/gpg.nix
    ../features/cli/optional/gpg-agent.nix

    ../features/cli/optional/bat.nix
    ../features/cli/optional/nix-index.nix
    ../features/cli/optional/ffmpeg.nix
    ../features/cli/optional/ranger.nix
    ../features/cli/optional/starship.nix
    ../features/cli/optional/zoxide.nix
  ]
  ++
  [
    ../features/desktop/i3
    (if X then ../features/desktop/optional/flameshot.nix else ../features/desktop/optional/grimshot.nix)
    ../features/desktop/optional/thunar.nix
    ../features/desktop/optional/mpv.nix
    ../features/desktop/optional/feh.nix
    ../features/desktop/optional/low-battery.nix
    ../features/desktop/optional/services-failed.nix

    ../features/desktop/optional/firefox.nix
    ../features/desktop/optional/chromium.nix
    # ../features/desktop/optional/chrome.nix
  ]
  ++
  [
    ../features/desktop/optional/kdeconnect.nix
    ../features/desktop/optional/safeeyes.nix
    (if X then ../features/desktop/optional/peek.nix else ../features/desktop/optional/kooha.nix)
    # ../features/desktop/optional/thunderbird.nix
    ../features/desktop/optional/joplin.nix
    ../features/desktop/optional/bitwarden.nix
    ../features/desktop/optional/libreoffice.nix
    ../features/desktop/optional/zathura.nix
    ../features/desktop/optional/scrcpy.nix
    ../features/desktop/optional/remmina.nix
  ]
  ++
  [
    ../features/cli/optional/sqlite.nix
    ../features/desktop/optional/sqlitebrowser.nix
  ]
  ++
  [
    ../features/desktop/optional/vscode.nix
    ../features/dev/optional/go.nix
    ../features/dev/optional/flutter.nix
    ../features/desktop/optional/android-studio.nix
  ]
  ;

  home.username = lib.mkDefault "${userName}";

  programs.ssh.matchBlocks = lib.mergeAttrs
    inputs.nixos-privates.ssh."common".matchBlocks
    inputs.nixos-privates.ssh."laptop".matchBlocks;
  programs.firefox.profiles.default.bookmarks = lib.mkAfter inputs.nixos-privates.firefox."laptop".bookmarks;
  programs.gpg.publicKeys = lib.mkAfter inputs.nixos-privates.gpg."laptop".publicKeys;
  services.gpg-agent.sshKeys = lib.mkForce inputs.nixos-privates.gpg."laptop".sshKeys;
  programs.git.aliases."signing" = "!git config commit.gpgsign true && git config tag.gpgsign true && git config user.signingkey ${inputs.nixos-privates.gpg."laptop".git-signingkey}";

  # https://github.com/nix-community/home-manager/issues/4804#issuecomment-1871272189
  # services.gpg-agent.pinentryFlavor = "qt";
  services.gpg-agent.pinentryPackage = pkgs.pinentry-qt;

  services.kanshi = lib.optionalAttrs (!X) {
    enable = true;
    profiles = {
      default = {
        outputs = [
          {
            criteria = "${inputs.nixos-privates.monitors."${nixosConfig.networking.hostName}-embedded".name}";
            status = "enable";
          }
        ];
      };
      "with-dell-1" = {
        # 如果没有哪个 ws 有窗口，就切换到 ws1
        exec = [ ''[ "''$(${pkgs.sway}/bin/swaymsg -t get_tree | ${lib.getExe pkgs.jq} -r '.. | select(.nodes? and .id? and .idle_inhibitors?) | .id' | ${pkgs.coreutils}/bin/wc -l)" -ne "0" ] || ${pkgs.sway}/bin/swaymsg workspace 1'' ];
        outputs = [
          {
            criteria = "${inputs.nixos-privates.monitors."${nixosConfig.networking.hostName}-embedded".name}";
            status = "disable";
          }
          {
            criteria = "${inputs.nixos-privates.monitors."dell-1".kanshi}";
            status = "enable";
          }
        ];
      };
    };
  };

  programs.autorandr = lib.optionalAttrs X {
    enable = true;
    profiles = {
      default = {
        fingerprint = {
          "${inputs.nixos-privates.monitors."${nixosConfig.networking.hostName}-embedded".name}" = "${inputs.nixos-privates.monitors."${nixosConfig.networking.hostName}-embedded".fingerprint}";
        };
        config = {
          "${inputs.nixos-privates.monitors."${nixosConfig.networking.hostName}-embedded".name}" = {
            enable = true;
            primary = true;
            position = "0x0";
            mode = "${inputs.nixos-privates.monitors."${nixosConfig.networking.hostName}-embedded".mode}";
            rate = "60.00";
          };
        };
      };
      "with-dell-1" = {
        fingerprint = {
          "${inputs.nixos-privates.monitors."${nixosConfig.networking.hostName}-embedded".name}" = "${inputs.nixos-privates.monitors."${nixosConfig.networking.hostName}-embedded".fingerprint}";
          "${inputs.nixos-privates.monitors."dell-1".name}" = "${inputs.nixos-privates.monitors."dell-1".fingerprint}";
        };
        config = {
          "${inputs.nixos-privates.monitors."${nixosConfig.networking.hostName}-embedded".name}" = {
            enable = false;
            primary = false;
            position = "0x0";
            mode = "${inputs.nixos-privates.monitors."${nixosConfig.networking.hostName}-embedded".mode}";
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
              DPI=${inputs.nixos-privates.monitors."${nixosConfig.networking.hostName}-embedded".dpi}
              ;;
            with-dell-1)
              DPI=${inputs.nixos-privates.monitors."dell-1".dpi}
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
