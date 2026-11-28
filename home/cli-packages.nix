{
  pkgs,
  lib ? pkgs.lib,
  nixosConfig ? { },
  ...
}:
let
  gitSigning = pkgs.writeShellApplication {
    name = "git-signing";
    runtimeInputs = [ pkgs.gitMinimal ];
    text = ''
      git config --get user.signingkey >/dev/null
      git config commit.gpgsign true
      git config tag.gpgsign true
    '';
  };
  gitBackup = pkgs.writeShellApplication {
    name = "git-backup";
    runtimeInputs = with pkgs; [
      coreutils
      gitMinimal
    ];
    text = ''
      usage() {
        echo "Usage: git backup [-f | --force] <name>" >&2
        exit 2
      }
      if (($# < 1)); then
        usage
      fi

      force=false
      backup_name=""
      backup_root="$HOME/backups/git"
      backup_remote="laptop-git-backup"

      while (($# > 0)); do
        case "$1" in
          -f | --force)
            force=true
            ;;
          -*)
            echo "Invalid option: $1" >&2
            usage
            ;;
          *)
            if [[ -n "$backup_name" ]]; then
              usage
            fi
            backup_name="$1"
            ;;
        esac
        shift
      done

      if [[ -z "$backup_name" || "$backup_name" == */* || "$backup_name" == "." || "$backup_name" == ".." ]]; then
        usage
      fi

      if ! git rev-parse --git-dir >/dev/null 2>&1; then
        echo "this is not a git repo" >&2
        exit 1
      fi

      target_repo="$backup_root/$backup_name"
      if git remote get-url origin >/dev/null 2>&1; then
        git remote set-url --delete origin "$target_repo" 2>/dev/null || true
        git remote set-url --add origin "$target_repo"
      elif [[ "$force" != true ]]; then
        echo "run git remote add origin" >&2
        exit 1
      fi

      if ! git remote get-url "$backup_remote" >/dev/null 2>&1; then
        git remote add "$backup_remote" "file:///dev/null"
        git remote set-url --push "$backup_remote" "$target_repo"
      fi

      if [[ ! -f "$target_repo/HEAD" ]]; then
        git init --bare "$target_repo"
      fi

      git remote -v
    '';
  };
in
{
  home.packages =
    (with pkgs; [
      screen
      bat
      zoxide
      starship
      gnupg
      fzf
      fd
      ripgrep
      hyperfine
      aria2
      sysstat
      usbutils
      wget
      tcpdump
      ipset
      inotify-tools
      inetutils
      netcat-openbsd
      nix-prefetch
      nix-prefetch-scripts
      (p7zip.override { enableUnfree = true; })
      gitSigning
      gitBackup
    ])
    ++ (import ./containers.nix { inherit pkgs lib nixosConfig; });
}
