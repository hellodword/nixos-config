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
  userName = config.home.username;
  buildTmp = nixosConfig.systemd.services.nix-daemon.environment.TMPDIR or "/tmp";
  identityRuntime = "/run/site-identity/${config.home.username}/current";
  gitDefaults = builtins.fromJSON (builtins.readFile ../data/git.json);
in
{
  imports = [ (lib.mkIf cfg.enable (import ./cli-packages.nix { inherit pkgs; })) ];
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
        "ignorespace"
        "ignoredups"
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
        "l" = "ls -CF";
        "la" = "ls -A";
        "ll" = "ls -alF";
        "ls" = "ls --color=auto";
        "7zaencrypt" = "7za -tzip -mem=AES256 -mx9 -p a";
        "feh" = "feh --scale-down --auto-zoom";
        "bat" = "bat -p";
        "emcc" = "docker run --rm -v $(pwd):/src -u $(id -u):$(id -g) emscripten/emsdk emcc";
        "gobuild" = "go build -trimpath -ldflags '-s -w -buildid='";
        "nixos-rebuild-boot" =
          "sudo echo; env TMPDIR=${buildTmp} nixos-rebuild --show-trace --verbose --sudo boot --flake .#${nixosConfig.networking.hostName}";
        "nixos-rebuild-boot-nom" =
          "sudo echo; env TMPDIR=${buildTmp} nixos-rebuild --show-trace --verbose --sudo boot --flake .#${nixosConfig.networking.hostName} |& ${pkgs.nix-output-monitor}/bin/nom";
        "nixos-rebuild-boot-offline" =
          "sudo echo; env TMPDIR=${buildTmp} nixos-rebuild --sudo boot --option substitute false --flake .#${nixosConfig.networking.hostName}";
        "toplevel" =
          "nix build .#nixosConfigurations.${nixosConfig.networking.hostName}.config.system.build.toplevel";

        "sha3-224sum" = "openssl dgst -sha3-224";
        "sha3-256sum" = "openssl dgst -sha3-256";
        "sha3-384sum" = "openssl dgst -sha3-384";
        "sha3-512sum" = "openssl dgst -sha3-512";

        "rp" = "rp() { realpath \"\$(which \"\$1\")\" ;}; rp";

        "sing-box-log" = "sudo journalctl --namespace=network -fu sing-box.service";
        "sing-box-config" = "sudo cat /run/sing-box/config.json | jq";

        "nix-prefetch-url-sha256" =
          "nix-prefetch-url-sha256() { nix hash to-sri --type sha256 \"$(nix-prefetch-url $1)\"; }; nix-prefetch-url-sha256";
        "nix-prefetch-patch" =
          ''nix-prefetch-patch() { nix build --impure --expr "(import <nixpkgs> {}).fetchpatch { url = \"$1\"; }"; }; nix-prefetch-patch'';

        "nix-outpath" =
          ''nix-outpath () { nix eval --impure --expr "(import <nixpkgs> {}).$1.outPath" | sed -E "s@(^\"|\"$)@@g"; }; nix-outpath'';
        "nix-meta" =
          ''nix-meta () { nix eval --impure --expr "builtins.toJSON ((import <nixpkgs> {}).$1.meta // { platforms = null; })" | sed -E "s@/nix/store/[^\n\/]+@https://github.com/NixOS/nixpkgs/blob/nixos-unstable@" | sed -E "s@\.nix:[0-9]+@\.nix@" | jq -r | jq; }; nix-meta'';

        "gen-passwd" =
          ''gen-passwd () { openssl kdf -binary -keylen "''${1:-32}" -kdfopt digest:SHA512 -kdfopt pass:"$(openssl rand -base64 48)" -kdfopt salt:salt -kdfopt iter:1000000 PBKDF2 | openssl base64 | tr -d "=+/" | cut -c1-''${1:-32}; }; gen-passwd'';

        "code." = "code .";
        "ffmpeg" = "ffmpeg -hide_banner";
        "ffplay" = "ffplay -hide_banner -nodisp -autoexit";

        "qrencode" = "docker run --rm -i --network none --runtime runsc leplusorg/qrcode qrencode -t utf8";
        "qrencode-png" =
          "docker run --rm -i --network none --runtime runsc leplusorg/qrcode qrencode -t png -o /dev/stdout";

        "nix-repl" = "nix repl --impure --expr 'import <nixpkgs>{}'";

        "docker-rmi-none-images" =
          "docker images --format json -a | grep '\"Digest\":\"\"' | jq -r '.ID' | xargs docker rmi";

        "gopeed" =
          ''docker run --rm --runtime runsc --name gopeed -v "$HOME/Downloads/gopeed/Downloads":/app/Downloads -v "$HOME/Downloads/gopeed/storage":/app/storage -p 127.0.0.1:9999:9999 --user "$(id -u)":"$(id -g)" --entrypoint /app/gopeed liwei2633/gopeed'';

        "mitm" =
          "mkdir -p ~/Downloads/.mitmproxy; docker run --rm -t --name mitm --network host -v ~/Downloads/.mitmproxy:/home/mitmproxy/.mitmproxy -v ~/dev/playground/mitmproxy-playground/scripts:/home/mitmproxy/.mitmproxy/scripts -w /home/mitmproxy/.mitmproxy/scripts mitmproxy/mitmproxy:dev mitmweb --mode socks5@8889 --mode regular@8888 --web-host 127.0.0.1 --web-port 8890 --ignore-hosts 8.8.8.8:443 --ignore-hosts 8.8.4.4:443 --ignore-hosts dns.google:443 --ignore-hosts dns.google --ignore-hosts 1.1.1.1:443 --ignore-hosts 1.0.0.1:443";

        "honor-downloader" =
          ''mkdir -p ~/Downloads/honor-downloader; docker run --rm --name honor-downloader --runtime runsc -v ~/Downloads/honor-downloader:/tmp --user "$(id -u):$(id -g)" ghcr.io/hellodword/honor-downloader'';

        "charles" =
          "mkdir -p ~/Downloads/charles; docker run --rm --name charles -v ~/Downloads/charles:/home/app -p 127.0.0.1:5800:5800 -p 8888:8888 -p 8889:8889 ghcr.io/hellodword/charles";

        "wg-serve" =
          ''mkdir -p ~/Downloads/wireguard-config; docker run --rm --name=wireguard --cap-add=NET_ADMIN -v ~/Downloads/wireguard-config:/config -e PUID="$(id -u)" -e PGID="$(id -g)" -e TZ=Etc/UTC -e PEERS=1 -e PEERDNS="1.1.1.1" -e PERSISTENTKEEPALIVE_PEERS="all" -e LOG_CONFS=true -p 51820:51820/udp --sysctl="net.ipv4.conf.all.src_valid_mark=1" linuxserver/wireguard:latest'';

        "ollama-up" =
          ''docker kill ollama || true; docker rm ollama || true; docker run -d --runtime runsc --name ollama --restart always --user "$(id -u)":"$(id -g)" -p 127.0.0.1:11434:11434 -v ~/Downloads/ollama:/home/ubuntu/.ollama ollama/ollama'';
        "ollama" = "docker exec -it ollama ollama";
      };
      initExtra = ''
        ${lib.optionalString nixosConfig.services.tailscale.enable "source <(tailscale completion bash)"}
        complete -c rp
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
        _devc_run() {
          local mode="$1"
          local refresh_layout=0
          shift
          while (($# > 0)); do
            case "''${1:-}" in
              --dry-run)
                mode="dry"
                shift
                ;;
              --refresh-cache-layout)
                refresh_layout=1
                shift
                ;;
              --)
                shift
                break
                ;;
              *)
                break
                ;;
            esac
          done

          local image="ghcr.io/hellodword/devcontainers-dev:latest"
          local layout_url="https://raw.githubusercontent.com/hellodword/devcontainers.nix/master/data/cache-layout.json"
          local workdir repo_name name_prefix rand_hex container_name state_root layout_cache layout_json
          local codex_dir gemini_dir opencode_config_dir opencode_data_dir opencode_state_dir
          local parsed_mounts cache_id cache_target cache_mode entry dir cache_dir guard target rendered
          local tty_flags=(-i) ro_mounts=() cache_mounts=() cache_dirs=() cmd=()

          workdir="$(pwd -P)" || return 1
          repo_name="$(basename "$workdir")"
          [[ -n "$repo_name" && "$repo_name" != "/" ]] || repo_name="workspace"
          rand_hex="$(od -vAn -N4 -tx1 /dev/urandom | tr -d ' \n' | tr '[:lower:]' '[:upper:]')"
          [[ -n "$rand_hex" ]] || return 1
          name_prefix="$(printf '%s' "$repo_name" | tr -cs '[:alnum:]_.-' '-')"
          name_prefix="''${name_prefix#"''${name_prefix%%[[:alnum:]]*}"}"
          while [[ "$name_prefix" == *[-.] ]]; do
            name_prefix="''${name_prefix%?}"
          done
          [[ -n "$name_prefix" ]] || name_prefix="workspace"
          container_name="''${name_prefix}-''${rand_hex}"

          state_root="''${XDG_STATE_HOME:-$HOME/.local/state}/devcontainers"
          layout_cache="$state_root/cache-layout.json"
          codex_dir="$HOME/.codex"
          gemini_dir="$HOME/.gemini"
          opencode_config_dir="''${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
          opencode_data_dir="''${XDG_DATA_HOME:-$HOME/.local/share}/opencode"
          opencode_state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/opencode"

          layout_json=""
          if (( refresh_layout == 0 )); then
            layout_json="$(docker image inspect --format '{{ index .Config.Labels "devcontainers.nix.cache-layout" }}' "$image" 2>/dev/null || true)"
            if [[ -z "$layout_json" && -s "$layout_cache" ]]; then
              layout_json="$(<"$layout_cache")" || return 1
            fi
          fi
          if [[ -z "$layout_json" ]]; then
            if layout_json="$(${pkgs.curl}/bin/curl -fsSL --connect-timeout 5 --max-time 15 "$layout_url")"; then
              ${pkgs.jq}/bin/jq -e '.version == 1 and (.mounts | type == "array" and length > 0)' >/dev/null <<<"$layout_json" || return 1
              install -d -m 0700 "$state_root" || return 1
              local tmp_layout
              tmp_layout="$(mktemp "$state_root/.cache-layout.XXXXXX")" || return 1
              if ! printf '%s\n' "$layout_json" >"$tmp_layout" || ! chmod 0600 "$tmp_layout" || ! mv -f "$tmp_layout" "$layout_cache"; then
                rm -f "$tmp_layout"
                return 1
              fi
            else
              layout_json="$(docker image inspect --format '{{ index .Config.Labels "devcontainers.nix.cache-layout" }}' "$image" 2>/dev/null || true)"
              [[ -n "$layout_json" ]] || return 1
            fi
          fi

          parsed_mounts="$(
            ${pkgs.jq}/bin/jq -er '
              if type != "object" or .version != 1 or (.mounts | type) != "array" or (.mounts | length) == 0 then
                error("invalid cache-layout schema")
              else
                .mounts[]
                | if (.id | type) != "string" or (.id | test("^[a-z0-9][a-z0-9._-]*$") | not) then
                    error("invalid cache mount id")
                  elif (.target | type) != "string" or (.target | test("^/(home/vscode|var/cache)/") | not) or (.target | test("(^|/)\\.\\.(/|$)")) then
                    error("invalid cache mount target")
                  elif (.mode | type) != "string" or (.mode | test("^0[0-7]{3}$") | not) then
                    error("invalid cache mount mode")
                  else
                    [.id, .target, .mode] | @tsv
                  end
              end
            ' <<<"$layout_json"
          )" || return 1

          while IFS=$'\t' read -r cache_id cache_target cache_mode; do
            [[ -n "$cache_id" ]] || continue
            cache_mounts+=(-v "$state_root/cache/$cache_id:$cache_target")
            cache_dirs+=("$cache_mode:$state_root/cache/$cache_id")
          done <<<"$parsed_mounts"

          if [[ -t 0 && -t 1 ]]; then
            tty_flags+=(-t)
          fi

          for guard in .devcontainer AGENTS.md .agents; do
            if [[ -e "$workdir/$guard" ]]; then
              target="$(realpath "$workdir/$guard")" || return 1
              ro_mounts+=(-v "$target:/workspaces/$repo_name/$guard:ro")
            fi
          done

          cmd=(
            docker run --rm
            --name "$container_name"
            "''${tty_flags[@]}"
            --init
            --cap-drop=ALL
            --security-opt=no-new-privileges:true
            -v "$workdir:/workspaces/$repo_name"
            "''${ro_mounts[@]}"
            -v "$codex_dir:/home/vscode/.codex"
            -v "$gemini_dir:/home/vscode/.gemini"
            -v "$opencode_config_dir:/home/vscode/.config/opencode"
            -v "$opencode_data_dir:/home/vscode/.local/share/opencode"
            -v "$opencode_state_dir:/home/vscode/.local/state/opencode"
            "''${cache_mounts[@]}"
            -w "/workspaces/$repo_name"
            "$image"
            "$@"
          )
          printf -v rendered '%q ' "''${cmd[@]}"

          if [[ "$mode" == "dry" ]]; then
            printf '%s\n' "''${rendered% }"
            return 0
          fi

          for dir in \
            "$codex_dir" \
            "$gemini_dir" \
            "$opencode_config_dir" \
            "$opencode_data_dir" \
            "$opencode_state_dir" \
            "$state_root" \
            "$state_root/cache"; do
            [[ -d "$dir" ]] || install -d -m 0700 "$dir" || return 1
          done
          for entry in "''${cache_dirs[@]}"; do
            cache_dir="''${entry#*:}"
            [[ -d "$cache_dir" ]] || install -d -m "''${entry%%:*}" "$cache_dir" || return 1
          done

          printf '%s\n' "''${rendered% }" >&2
          "''${cmd[@]}"
        }
        devc() {
          _devc_run run "$@"
        }
        devc-dry() {
          _devc_run dry "$@"
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
            command = ''[ -d "$(git remote get-url --push laptop-git-backup)" ] || echo ❌❌❌ NOT BACKUP'';
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
        };
    };
    programs.git = {
      enable = true;
      package = pkgs.gitFull;
      settings = lib.recursiveUpdate gitDefaults {
        gpg.format = "openpgp";
        alias.signing = "!git config --get user.signingkey >/dev/null && git config commit.gpgsign true && git config tag.gpgsign true";
        alias.backup = ''
          !f() {
            usage() {
                echo "Usage: git backup [-f | --force] <name>"
                exit 1
            }

            if [ $# -lt 1 ]; then
                usage
            fi

            local FORCE=false
            local BACKUP_NAME=""
            local BACKUP_ROOT="$HOME/backups/git"
            local BACKUP_REMOTE="laptop-git-backup"

            while [[ "$1" != "" ]]; do
                case $1 in
                    -f | --force )
                        FORCE=true
                        ;;
                    -* )
                        echo "Invalid option: $1"
                        usage
                        ;;
                    * )
                        BACKUP_NAME="$1"
                        ;;
                esac
                shift
            done

            if [ -z "$BACKUP_NAME" ]; then
              usage
            fi

            if [ ! -d ".git" ]; then
              echo "this is not a git repo"
              exit 1
            fi

            if git remote get-url origin >/dev/null 2>/dev/null; then
              git remote set-url --delete origin "$BACKUP_ROOT/$BACKUP_NAME" 2>/dev/null || true
              git remote set-url --add origin "$BACKUP_ROOT/$BACKUP_NAME"
            else
              if ! "$FORCE"; then
                echo "run git remote add origin"
                exit 1
              fi
            fi

            if ! git remote get-url "$BACKUP_REMOTE" >/dev/null 2>/dev/null; then
              git remote add "$BACKUP_REMOTE" "file:///dev/null"
              git remote set-url --push "$BACKUP_REMOTE" "$BACKUP_ROOT/$BACKUP_NAME"
            fi

            if [ ! -f "$BACKUP_ROOT/$BACKUP_NAME/HEAD" ]; then
              git init --bare "$BACKUP_ROOT/$BACKUP_NAME"
            fi

            git remote -v
          };
          f'';
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
