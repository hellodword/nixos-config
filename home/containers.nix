# Host container launchers and isolated third-party CLI wrappers.
# Untrusted third-party binaries and network/parsing utilities below (qrencode,
# apkid, emcc, honor-downloader, gopeed, charles, mitm, wg-serve) run inside
# Docker / gVisor (runsc) containers rather than executing directly on the host.
{
  pkgs,
  lib ? pkgs.lib,
  nixosConfig ? { },
}:
let
  formatEndpointHost = addr: if lib.hasInfix ":" addr then "[${addr}]" else addr;
  rawBip = nixosConfig.virtualisation.docker.daemon.settings.bip or "172.17.0.1/16";
  bridgeIp = lib.head (lib.splitString "/" rawBip);
  resolveBridgeAddr =
    addr:
    if
      lib.elem addr [
        "127.0.0.1"
        "::1"
      ]
    then
      null
    else if
      lib.elem addr [
        "0.0.0.0"
        "::"
      ]
    then
      bridgeIp
    else
      addr;

  siteCache = nixosConfig.site.cache or { };
  localCacheHost =
    if (siteCache.enable or false) then
      resolveBridgeAddr (siteCache.listenAddress or "127.0.0.1")
    else
      null;
  localCacheEndpoint =
    if localCacheHost != null then
      "${formatEndpointHost localCacheHost}:${toString (siteCache.port or 37515)}"
    else
      "";

  siteContainers = nixosConfig.site.containers or { };
  hostStoreCfg = siteContainers.hostStoreCache or { };
  hostStoreHost =
    if (siteContainers.enable or false) && (hostStoreCfg.enable or false) then
      resolveBridgeAddr (hostStoreCfg.listenAddress or "172.17.0.1")
    else
      null;
  hostStoreEndpoint =
    if hostStoreHost != null then
      "${formatEndpointHost hostStoreHost}:${toString (hostStoreCfg.port or 37516)}"
    else
      "";

  devcBin = pkgs.writeShellApplication {
    name = "devc";
    runtimeInputs = with pkgs; [
      coreutils
      docker
      jq
    ];
    text = ''
      mode="run"
      enable_android=0
      pull_policy="missing"
      net_none=0
      docker_args=()
      while (($# > 0)); do
        case "$1" in
          --dry-run)
            mode="dry"
            shift
            ;;
          --android)
            enable_android=1
            shift
            ;;
          --pull=*)
            pull_policy="''${1#--pull=}"
            shift
            ;;
          --pull)
            if (($# < 2)); then
              echo "devc: --pull requires a value (always|missing|never)" >&2
              exit 2
            fi
            pull_policy="$2"
            shift 2
            ;;
          --network=none | --net=none)
            net_none=1
            docker_args+=("$1")
            shift
            ;;
          --network | --net)
            if (($# >= 2)) && [[ "$2" == "none" ]]; then
              net_none=1
            fi
            docker_args+=("$1")
            shift
            ;;
          *)
            docker_args+=("$1")
            shift
            ;;
        esac
      done

      case "$pull_policy" in
        always | missing | never) ;;
        *)
          echo "devc: unsupported --pull policy: $pull_policy" >&2
          exit 2
          ;;
      esac

      image="ghcr.io/hellodword/devcontainers-dev:latest"
      local_cache_addr=${lib.escapeShellArg localCacheEndpoint}
      host_store_cache_addr=${lib.escapeShellArg hostStoreEndpoint}
      ro_mounts=()
      cache_mounts=()
      cache_dirs=()
      cache_env_args=()

      if ((net_none == 0)); then
        if [[ -n "$local_cache_addr" ]]; then
          cache_env_args+=(-e "DEVCONTAINER_LOCAL_CACHE_ADDR=$local_cache_addr")
        fi
        if [[ -n "$host_store_cache_addr" ]]; then
          cache_env_args+=(-e "DEVCONTAINER_HOST_STORE_CACHE_ADDR=$host_store_cache_addr")
        fi
      fi

      workdir="$(pwd -P)"
      repo_name="$(basename "$workdir")"
      [[ -n "$repo_name" && "$repo_name" != "/" ]] || repo_name="workspace"
      rand_hex="$(od -vAn -N4 -tx1 /dev/urandom | tr -d ' \n' | tr '[:lower:]' '[:upper:]')"
      [[ -n "$rand_hex" ]]
      name_prefix="$(printf '%s' "$repo_name" | tr -cs '[:alnum:]_.-' '-')"
      name_prefix="''${name_prefix#"''${name_prefix%%[[:alnum:]]*}"}"
      while [[ "$name_prefix" == *[-.] ]]; do
        name_prefix="''${name_prefix%?}"
      done
      [[ -n "$name_prefix" ]] || name_prefix="workspace"
      container_name="''${name_prefix}-''${rand_hex}"

      state_root="''${XDG_STATE_HOME:-$HOME/.local/state}/devcontainers"
      codex_dir="$HOME/.codex"
      gemini_dir="$HOME/.gemini"
      opencode_config_dir="''${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
      opencode_data_dir="''${XDG_DATA_HOME:-$HOME/.local/share}/opencode"
      opencode_state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/opencode"

      if [[ "$mode" == "run" ]]; then
        if [[ "$pull_policy" == "always" ]]; then
          docker image pull "$image"
        elif [[ "$pull_policy" == "missing" ]] && ! docker image inspect "$image" >/dev/null 2>&1; then
          docker image pull "$image"
        fi
      fi

      if ! inspect_json="$(docker image inspect "$image" 2>&1)"; then
        printf '%s\n' "$inspect_json" >&2
        exit 1
      fi

      image_id="$(jq -er '.[0].Id' <<<"$inspect_json")"
      layout_json="$(jq -r '.[0].Config.Labels["devcontainers.nix.cache-layout"] // empty' <<<"$inspect_json")"
      if [[ -z "$layout_json" ]]; then
        echo "devc: image $image ($image_id) is missing label devcontainers.nix.cache-layout" >&2
        exit 1
      fi

      parsed_mounts="$(
        jq -er '
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
      )"

      while IFS=$'\t' read -r cache_id cache_target cache_mode; do
        [[ -n "$cache_id" ]] || continue
        cache_mounts+=(-v "$state_root/cache/$cache_id:$cache_target")
        cache_dirs+=("$cache_mode:$state_root/cache/$cache_id")
      done <<<"$parsed_mounts"

      if [[ -e "$workdir/.devcontainer" ]]; then
        target="$(realpath -e -- "$workdir/.devcontainer")"
        ro_mounts+=(-v "$target:/workspaces/$repo_name/.devcontainer:ro")
      fi

      rule_base="$HOME/dev/workspace/agents-misc"
      for rule in AGENTS.md .agents; do
        if [[ ! -e "$rule_base/$rule" ]]; then
          echo "devc: missing $rule_base/$rule" >&2
          exit 1
        fi
        if [[ -d "$workdir/$rule" ]]; then
          if [[ -n "$(ls -A -- "$workdir/$rule")" ]]; then
            echo "devc: refusing to shadow non-empty $workdir/$rule" >&2
            exit 1
          fi
        elif [[ -s "$workdir/$rule" || -L "$workdir/$rule" ]]; then
          echo "devc: refusing to shadow non-empty $workdir/$rule" >&2
          exit 1
        fi
        target="$(realpath -e -- "$rule_base/$rule")"
        ro_mounts+=(-v "$target:/workspaces/$repo_name/$rule:ro")
      done

      android_dir="$HOME/.android"
      android_args=()
      if ((enable_android == 1)); then
        if [[ "$mode" == "run" ]]; then
          if [[ ! -d /dev/bus/usb ]]; then
            echo "devc: /dev/bus/usb is not available on the host" >&2
            exit 1
          fi
          if [[ ! -e "$android_dir/adbkey" && ! -e "$android_dir/adbkey.pub" ]] && command -v adb >/dev/null 2>&1; then
            install -d -m 0700 "$android_dir"
            adb keygen "$android_dir/adbkey"
            chmod 0600 "$android_dir/adbkey"
            chmod 0644 "$android_dir/adbkey.pub"
          fi
          if [[ ! -f "$android_dir/adbkey" || ! -f "$android_dir/adbkey.pub" ]]; then
            echo "devc: missing regular files $android_dir/adbkey(.pub); run 'adb keygen ~/.android/adbkey' first" >&2
            exit 1
          fi
          adbkey_file="$(realpath -e -- "$android_dir/adbkey")"
          adbkey_pub_file="$(realpath -e -- "$android_dir/adbkey.pub")"
        else
          adbkey_file="$android_dir/adbkey"
          adbkey_pub_file="$android_dir/adbkey.pub"
          if [[ -f "$adbkey_file" ]]; then
            adbkey_file="$(realpath -e -- "$adbkey_file")"
          fi
          if [[ -f "$adbkey_pub_file" ]]; then
            adbkey_pub_file="$(realpath -e -- "$adbkey_pub_file")"
          fi
        fi
        android_args=(
          --device-cgroup-rule='c 189:* rmw'
          -v /dev/bus/usb:/dev/bus/usb
          -v "$adbkey_file:/home/vscode/.android/adbkey:ro"
          -v "$adbkey_pub_file:/home/vscode/.android/adbkey.pub:ro"
        )
      fi

      cmd=(
        docker run --rm -it --pull=never
        --name "$container_name"
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
        "''${android_args[@]}"
        -w "/workspaces/$repo_name"
        "''${cache_env_args[@]}"
        "''${docker_args[@]}"
        "$image_id"
        bash
      )

      if [[ "$mode" == "dry" ]]; then
        printf -v rendered '%q ' "''${cmd[@]}"
        printf '%s\n' "''${rendered% }"
        exit 0
      fi

      for dir in \
        "$codex_dir" \
        "$gemini_dir" \
        "$opencode_config_dir" \
        "$opencode_data_dir" \
        "$opencode_state_dir" \
        "$state_root" \
        "$state_root/cache"; do
        [[ -d "$dir" ]] || install -d -m 0700 "$dir"
      done
      for entry in "''${cache_dirs[@]}"; do
        cache_dir="''${entry#*:}"
        [[ -d "$cache_dir" ]] || install -d -m "''${entry%%:*}" "$cache_dir"
      done

      exec "''${cmd[@]}"
    '';
  };

  devcDryBin = pkgs.writeShellApplication {
    name = "devc-dry";
    runtimeInputs = [ devcBin ];
    text = ''
      exec devc --dry-run "$@"
    '';
  };

  devcSuite =
    pkgs.runCommand "devc-suite"
      {
        nativeBuildInputs = [ pkgs.shellcheck ];
      }
      ''
        mkdir -p "$out/bin" "$out/share/bash-completion/completions"
        ln -s ${devcBin}/bin/devc "$out/bin/devc"
        ln -s ${devcDryBin}/bin/devc-dry "$out/bin/devc-dry"

        cat > "$out/share/bash-completion/completions/devc" <<'EOF'
        _devc_complete() {
          local cur="''${COMP_WORDS[COMP_CWORD]}"
          if [[ "$cur" == -* ]]; then
            mapfile -t COMPREPLY < <(compgen -W "--android --dry-run --pull=always --pull=missing --pull=never -e --env -p --publish -v --volume --network" -- "$cur")
          fi
        }
        complete -o default -F _devc_complete devc devc-dry
        EOF
        shellcheck --shell=bash "$out/share/bash-completion/completions/devc"
        ln -s devc "$out/share/bash-completion/completions/devc-dry"
      '';
in
[
  devcSuite
  (pkgs.writeShellApplication {
    name = "qrencode";
    runtimeInputs = [ pkgs.docker ];
    text = ''
      exec docker run --rm --init --cap-drop=ALL --security-opt=no-new-privileges:true \
        --network=none --runtime=runsc -i leplusorg/qrcode qrencode -t utf8 "$@"
    '';
  })
  (pkgs.writeShellApplication {
    name = "qrencode-png";
    runtimeInputs = [ pkgs.docker ];
    text = ''
      exec docker run --rm --init --cap-drop=ALL --security-opt=no-new-privileges:true \
        --network=none --runtime=runsc -i leplusorg/qrcode qrencode -t png -o /dev/stdout "$@"
    '';
  })
  (pkgs.writeShellApplication {
    name = "apkid";
    runtimeInputs = with pkgs; [
      coreutils
      docker
    ];
    text = ''
      if (($# == 0)); then
        exec docker run --rm --init --cap-drop=ALL --security-opt=no-new-privileges:true \
          --network=none --runtime=runsc -i ghcr.io/hellodword/apkid --help
      fi
      for arg in "$@"; do
        case "$arg" in
          -h | --help | --version)
            exec docker run --rm --init --cap-drop=ALL --security-opt=no-new-privileges:true \
              --network=none --runtime=runsc -i ghcr.io/hellodword/apkid "$@"
            ;;
        esac
      done

      args=("$@")
      target_index=-1
      for ((i = ''${#args[@]} - 1; i >= 0; i--)); do
        if [[ "''${args[i]}" != -* && -e "''${args[i]}" ]]; then
          target_index=$i
          break
        fi
      done
      if ((target_index < 0)); then
        echo "apkid: target file does not exist" >&2
        exit 2
      fi

      target_path="$(realpath -e -- "''${args[target_index]}")"
      input_file="$(basename "$target_path")"
      args[target_index]="/input/$input_file"

      exec docker run --rm --init --cap-drop=ALL --security-opt=no-new-privileges:true \
        --network=none --runtime=runsc -i \
        --volume "$target_path:/input/$input_file:ro" \
        ghcr.io/hellodword/apkid "''${args[@]}"
    '';
  })
  (pkgs.writeShellApplication {
    name = "emcc";
    runtimeInputs = with pkgs; [
      coreutils
      docker
    ];
    text = ''
      workdir="$(pwd -P)"
      exec docker run --rm --init --cap-drop=ALL --security-opt=no-new-privileges:true \
        --network=none --runtime=runsc \
        -v "$workdir:/src" -w /src --user "$(id -u):$(id -g)" \
        emscripten/emsdk emcc "$@"
    '';
  })
  (pkgs.writeShellApplication {
    name = "honor-downloader";
    runtimeInputs = with pkgs; [
      coreutils
      docker
    ];
    text = ''
      mkdir -p "$HOME/Downloads/honor-downloader"
      exec docker run --rm --init --cap-drop=ALL --security-opt=no-new-privileges:true \
        --runtime=runsc --name honor-downloader \
        -v "$HOME/Downloads/honor-downloader:/tmp" --user "$(id -u):$(id -g)" \
        ghcr.io/hellodword/honor-downloader "$@"
    '';
  })
  (pkgs.writeShellApplication {
    name = "gopeed";
    runtimeInputs = with pkgs; [
      coreutils
      docker
    ];
    text = ''
      mkdir -p "$HOME/Downloads/gopeed/Downloads" "$HOME/Downloads/gopeed/storage"
      exec docker run --rm --init --cap-drop=ALL --security-opt=no-new-privileges:true \
        --runtime=runsc --name gopeed \
        -v "$HOME/Downloads/gopeed/Downloads:/app/Downloads" \
        -v "$HOME/Downloads/gopeed/storage:/app/storage" \
        -p 127.0.0.1:9999:9999 --user "$(id -u):$(id -g)" \
        --entrypoint /app/gopeed liwei2633/gopeed "$@"
    '';
  })
  (pkgs.writeShellApplication {
    name = "charles";
    runtimeInputs = with pkgs; [
      coreutils
      docker
    ];
    text = ''
      mkdir -p "$HOME/Downloads/charles"
      exec docker run --rm --init --runtime=runsc --name charles \
        -v "$HOME/Downloads/charles:/home/app" \
        -p 127.0.0.1:5800:5800 -p 8888:8888 -p 8889:8889 \
        ghcr.io/hellodword/charles "$@"
    '';
  })
  (pkgs.writeShellApplication {
    name = "mitm";
    runtimeInputs = with pkgs; [
      coreutils
      docker
    ];
    text = ''
      mkdir -p "$HOME/Downloads/.mitmproxy"
      extra_args=()
      scripts_dir="$HOME/dev/playground/mitmproxy-playground/scripts"
      if [[ -d "$scripts_dir" ]]; then
        extra_args+=(-v "$scripts_dir:/home/mitmproxy/.mitmproxy/scripts" -w /home/mitmproxy/.mitmproxy/scripts)
      fi
      exec docker run --rm --init -t --name mitm --network=host \
        -v "$HOME/Downloads/.mitmproxy:/home/mitmproxy/.mitmproxy" \
        "''${extra_args[@]}" \
        mitmproxy/mitmproxy:dev mitmweb \
        --mode socks5@8889 --mode regular@8888 \
        --web-host 127.0.0.1 --web-port 8890 \
        --ignore-hosts 8.8.8.8:443 --ignore-hosts 8.8.4.4:443 \
        --ignore-hosts dns.google:443 --ignore-hosts dns.google \
        --ignore-hosts 1.1.1.1:443 --ignore-hosts 1.0.0.1:443 \
        "$@"
    '';
  })
  (pkgs.writeShellApplication {
    name = "wg-serve";
    runtimeInputs = with pkgs; [
      coreutils
      docker
    ];
    text = ''
      mkdir -p "$HOME/Downloads/wireguard-config"
      exec docker run --rm --name=wireguard --cap-add=NET_ADMIN \
        -v "$HOME/Downloads/wireguard-config:/config" \
        -e PUID="$(id -u)" -e PGID="$(id -g)" \
        -e TZ=Etc/UTC -e PEERS=1 -e PEERDNS=1.1.1.1 \
        -e PERSISTENTKEEPALIVE_PEERS=all -e LOG_CONFS=true \
        -p 51820:51820/udp \
        --sysctl=net.ipv4.conf.all.src_valid_mark=1 \
        linuxserver/wireguard:latest "$@"
    '';
  })
]
