{
  config,
  lib,
  pkgs,
  nixosConfig,
  ...
}:
let
  cfg =
    nixosConfig.site.cli or {
      enable = false;
      identityFile = null;
    };
  identityRuntime = "/run/site-identity/${config.home.username}/current";
  gitDefaults = builtins.fromJSON (builtins.readFile ../data/git.json);
  hostSystem = pkgs.stdenv.hostPlatform.system;
  nixpkgsExpr = "(import ${pkgs.path} { system = \"${hostSystem}\"; config.allowUnfree = true; })";
in
{
  imports = [
    (lib.mkIf cfg.enable (
      import ./cli-packages.nix {
        inherit pkgs lib nixosConfig;
      }
    ))
  ];
  config = lib.mkIf cfg.enable {
    programs.bash = {
      enable = true;
      enableCompletion = true;
      enableVteIntegration = true;
      historyIgnore = [
        "ls"
        "cd"
      ];
      historyControl = [
        "ignoreboth"
        "erasedups"
      ];
      historySize = 10000;
      historyFileSize = 100000;
      shellOptions = [
        "histappend"
        "checkwinsize"
        "extglob"
        "globstar"
        "checkjobs"
      ];
      shellAliases = {
        "grep" = "grep --color=auto";
        "diff" = "diff --color=auto";
        "l" = "ls -CF";
        "la" = "ls -A";
        "ll" = "ls -alF";
        "ls" = "ls --color=auto";
        "7zaencrypt" = "7za -tzip -mem=AES256 -mx9 -p a";
        "feh" = "feh --scale-down --auto-zoom";
        "bat" = "bat -p";
        "sha3-224sum" = "openssl dgst -sha3-224";
        "sha3-256sum" = "openssl dgst -sha3-256";
        "sha3-384sum" = "openssl dgst -sha3-384";
        "sha3-512sum" = "openssl dgst -sha3-512";
        "sing-box-log" = "sudo journalctl --namespace=network -fu sing-box.service";
        "sing-box-config" = "sudo jq . /run/sing-box/config.json";
        "code." = "code .";
        "ffmpeg" = "ffmpeg -hide_banner";
        "ffplay" = "ffplay -hide_banner -nodisp -autoexit";
        "nix-repl" = "nix repl --expr '${nixpkgsExpr}'";
      };
      initExtra = ''
        ${lib.optionalString nixosConfig.services.tailscale.enable "source <(tailscale completion bash)"}
        rp() {
          local bin
          bin="$(type -P -- "$1")" || return 1
          realpath -e -- "$bin"
        }
        complete -c rp
        gen-passwd() {
          local len="''${1:-32}"
          LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$len"
          printf '\n'
        }
        nix-prefetch-url-sha256() {
          nix store prefetch-file --json -- "$1" | ${pkgs.jq}/bin/jq -r .hash
        }
        nix-prefetch-patch() {
          nix build --no-link --expr "(import ${pkgs.path} { system = \"${hostSystem}\"; }).fetchpatch { url = \"$1\"; hash = \"sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\"; }"
        }
        nix-outpath() {
          nix eval --raw --expr "${nixpkgsExpr}.$1.outPath"
          printf '\n'
        }
        nix-meta() {
          nix eval --json --expr "removeAttrs ${nixpkgsExpr}.$1.meta [ \"platforms\" \"badPlatforms\" ]" \
            | ${pkgs.jq}/bin/jq 'if .position then .position |= (sub("^/nix/store/[^/]+/"; "https://github.com/NixOS/nixpkgs/blob/nixos-unstable/") | sub(":(?<line>[0-9]+)$"; "#L\(.line)")) else . end'
        }
        bw-unlock() {
          local session
          session="$(bw unlock --raw)" || return "$?"
          [[ -n "$session" ]] || return 1
          export BW_SESSION="$session"
        }
        bw-lock() {
          local status=0
          bw lock || status=$?
          unset BW_SESSION
          return "$status"
        }
      '';
    };
    programs.zoxide = {
      enable = true;
      enableBashIntegration = true;
    };
    programs.starship = {
      enable = true;
      enableBashIntegration = true;
      settings =
        (lib.genAttrs
          [
            "aws"
            "azure"
            "buf"
            "localip"
            "gcloud"
            "git_status"
            "os"
            "package"
            "python"
            "time"
            "vcsh"
          ]
          (_: {
            disabled = true;
          })
        )
        // {
          shlvl.disabled = false;
          sudo.disabled = false;
          custom.git_backup_status = {
            command = ''[ -d "$(git remote get-url --push laptop-git-backup 2>/dev/null)" ] || echo ❌❌❌ NOT BACKUP'';
            require_repo = true;
            when = true;
            ignore_timeout = true;
            style = "bold yellow";
          };
          custom.bitwarden = {
            when = ''test -n "$BW_SESSION"'';
            shell = [
              "${pkgs.bash}/bin/bash"
              "--noprofile"
              "--norc"
            ];
            format = "[BW 会话变量已设置]($style) ";
            style = "bold yellow";
          };
          custom.network_direct = {
            when = "${pkgs.gnugrep}/bin/grep -Eq ':(|[^:]*net_cls[^:]*):(.*/)?mullvad-exclusions$' /proc/self/cgroup";
            shell = [
              "${pkgs.bash}/bin/bash"
              "--noprofile"
              "--norc"
            ];
            format = "[\\[DIRECT\\]]($style) ";
            style = "bold red";
          };
        };
    };
    programs.git = {
      enable = true;
      package = pkgs.gitFull;
      settings = lib.recursiveUpdate gitDefaults {
        gpg.format = "openpgp";
      };
      includes =
        lib.optionals (cfg.identityFile != null) [
          { path = "${identityRuntime}/git-identity.conf"; }
          { path = "${identityRuntime}/git-signing.conf"; }
        ]
        ++ [ { path = "~/.config/git/local.inc"; } ];
    };
    programs.ssh = {
      enable = true;
      enableDefaultConfig = false;
      includes = [
        "~/.ssh/hosts.d/*.conf"
      ]
      ++ lib.optional (cfg.identityFile != null) "${identityRuntime}/ssh.conf";
      settings."*" = {
        HashKnownHosts = true;
        ServerAliveInterval = 30;
        ServerAliveCountMax = 60;
        IdentitiesOnly = true;
        ForwardAgent = false;
        AddKeysToAgent = "no";
        StrictHostKeyChecking = "ask";
      };
      settings.kitty = {
        header = ''Match exec "test \"$TERM\" = xterm-kitty"'';
        SetEnv.TERM = "xterm-256color";
      };
    };
    programs.gpg = {
      enable = true;
      settings = {
        no-emit-version = true;
        no-comments = true;
        keyid-format = "0xlong";
        with-fingerprint = true;
        with-keygrip = true;
        personal-cipher-preferences = "AES256 AES192 AES";
        personal-digest-preferences = "SHA512 SHA384 SHA256";
        cert-digest-algo = "SHA512";
      };
    };
    programs.bat = {
      enable = true;
      config = {
        theme = "base16";
        style = "numbers,changes";
      };
    };
    home.file.".screenrc".text = "startup_message off\ndefbce on\nsetenv TERM xterm-256color\n";
  };
}
