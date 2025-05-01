{
  lib,
  inputs,
  pkgs,
  nixosConfig,
  userName,
  ...
}:

let
  X = nixosConfig.services.xserver.windowManager.i3.enable;
  switch-to-ws1 = pkgs.writeShellApplication {
    name = "exe";
    runtimeInputs =
      with pkgs;
      (lib.optionals (!X) [
        sway
        jq
        coreutils
      ]);
    text = lib.optionalString (!X) ''
      mkdir -p "$HOME"/.cache/kanshi

      if [ ! -f "$HOME"/.cache/kanshi/boot ]; then
        touch "$HOME"/.cache/kanshi/boot

        # sleep 1s
        # will mess up the rofi
        swaymsg workspace 1
      fi

      # swaymsg -t get_tree | jq > /tmp/switch-to-ws1.json
    '';
  };
  i3ConfigStartupExtra = (
    lib.optionalAttrs X {
      notification = false;
      workspace = null;
    }
  );
  # https://github.com/emersion/kanshi/issues/43
  startup = [
    (
      {
        command = "pkill kanshi; systemctl --user restart kanshi";
        always = true;
      }
      // i3ConfigStartupExtra
    )
  ];
in
{
  imports =
    [
      ../common/global
    ]
    ++ [
      ../common/features/cli
      ../common/features/cli/optional/scripts.nix

      ../common/features/cli/optional/gpg.nix
      ../common/features/cli/optional/gpg-agent.nix

      ../common/features/cli/optional/bat.nix
      ../common/features/cli/optional/nix-index.nix
      ../common/features/cli/optional/starship.nix
      ../common/features/cli/optional/zoxide.nix
    ]
    ++ [
      ../common/features/desktop/i3
      (
        if X then
          ../common/features/desktop/optional/flameshot.nix
        else
          ../common/features/desktop/optional/grimshot.nix
      )
      ../common/features/desktop/optional/mpv.nix
      ../common/features/desktop/optional/feh.nix
      ../common/features/desktop/optional/low-battery.nix
      ../common/features/desktop/optional/services-failed.nix

      ../common/features/desktop/optional/firefox.nix
      ../common/features/desktop/optional/chromium.nix
      # ../common/features/desktop/optional/chrome.nix
    ]
    ++ [
      ../common/features/desktop/optional/kdeconnect.nix
      ../common/features/desktop/optional/safeeyes.nix
      ../common/features/desktop/optional/anytype.nix
      ../common/features/desktop/optional/bitwarden.nix
      ../common/features/desktop/optional/libreoffice.nix
      ../common/features/desktop/optional/remmina.nix
      ../common/features/desktop/optional/blender.nix
    ]
    ++ [
      ../common/features/cli/optional/sqlite.nix
      ../common/features/desktop/optional/sqlitebrowser.nix
    ]
    ++ [
      ../common/features/desktop/optional/vscode.nix
      ../common/features/dev/optional/go.nix
      # ../common/features/dev/optional/flutter.nix
      ../common/features/dev/optional/android.nix
    ];

  home.username = lib.mkDefault "${userName}";

  programs.ssh.matchBlocks =
    lib.mergeAttrs
      (lib.mergeAttrs inputs.nixos-privates.ssh."common".matchBlocks
        inputs.nixos-privates.ssh."laptop".matchBlocks
      )
      (
        lib.attrsets.concatMapAttrs (
          k: v:
          lib.mergeAttrs { ${k} = v.ssh; } (
            builtins.listToAttrs (
              map (alias: {
                name = alias;
                value = v.ssh;
              }) (v.alias ++ (map (alias: "${k}-${alias}") v.alias))
            )
          )
        ) inputs.nixos-privates.servers
      );

  programs.gpg.publicKeys = lib.mkAfter inputs.nixos-privates.gpg."laptop".publicKeys;
  services.gpg-agent.sshKeys = lib.mkForce inputs.nixos-privates.gpg."laptop".sshKeys;
  programs.git.aliases."signing" =
    "!git config commit.gpgsign true && git config tag.gpgsign true && git config user.signingkey ${
      inputs.nixos-privates.gpg."laptop".git-signingkey
    }";

  # https://github.com/nix-community/home-manager/issues/4804#issuecomment-1871272189
  # services.gpg-agent.pinentryFlavor = "qt";
  services.gpg-agent.pinentry.package = pkgs.pinentry-qt;

  wayland.windowManager.sway.config.startup = (lib.optionals (!X) startup);

  services.kanshi = lib.optionalAttrs (!X) {
    enable = true;
    settings = [
      {
        profile.name = "default";
        profile.outputs = [
          {
            criteria = "${inputs.nixos-privates.monitors."${nixosConfig.networking.hostName}-embedded".name}";
            status = "enable";
          }
        ];
      }
      {
        profile.name = "with-dell-1";
        # 如果没有哪个 ws 有窗口，就切换到 ws1
        profile.exec = [
          "${switch-to-ws1}/bin/exe"
        ];
        profile.outputs = [
          {
            criteria = "${inputs.nixos-privates.monitors."${nixosConfig.networking.hostName}-embedded".name}";
            status = "disable";
          }
          {
            criteria = "${inputs.nixos-privates.monitors."dell-1".kanshi}";
            status = "enable";
          }
        ];
      }
    ];
  };

  programs.autorandr = lib.optionalAttrs X {
    enable = true;
    profiles = {
      default = {
        fingerprint = {
          "${inputs.nixos-privates.monitors."${nixosConfig.networking.hostName}-embedded".name}" =
            "${inputs.nixos-privates.monitors."${nixosConfig.networking.hostName}-embedded".fingerprint}";
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
          "${inputs.nixos-privates.monitors."${nixosConfig.networking.hostName}-embedded".name}" =
            "${inputs.nixos-privates.monitors."${nixosConfig.networking.hostName}-embedded".fingerprint}";
          "${inputs.nixos-privates.monitors."dell-1".name}" =
            "${inputs.nixos-privates.monitors."dell-1".fingerprint}";
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
