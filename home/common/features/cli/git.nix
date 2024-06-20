{ pkgs, ... }:

let
  GIT_BACKUP_DIR = "$HOME/backups/git";
  GIT_BACKUP_BRANCH = "laptop-git-backup";
in
{
  programs.git = {
    enable = true;
    package = pkgs.gitAndTools.gitFull;
    extraConfig = {
      core.editor = "vim";
    };
    aliases = {
      "config-github" = "!git config user.name hellodword && git config user.email 46193371+hellodword@users.noreply.github.com";
      "config-dependabot" = "!git config user.name dependabot[bot] && git config user.email 49699333+dependabot[bot]@users.noreply.github.com";
      "remote-add-github" = "!f() { git remote add origin git@hellodword.github.com:hellodword/$1.git; }; f";

      # push only https://stackoverflow.com/a/53706195
      "backup" = ''
        !f() {
          set -e

          local git_backup_name="$1"
          local git_backup_root="${GIT_BACKUP_DIR}"
          local git_backup_branch="${GIT_BACKUP_BRANCH}"

          if [ -z "$git_backup_name" ]; then
            echo "usage: git backup <name>"
            exit 1
          fi

          if [ ! -f "$git_backup_root/$git_backup_name/HEAD" ]; then
            git init --bare "$git_backup_root/$git_backup_name"
          fi

          git remote set-url --delete origin "$git_backup_root/$git_backup_name" 2>/dev/null || true
          git remote set-url --add origin "$git_backup_root/$git_backup_name"

          if ! git remote get-url "$git_backup_branch" >/dev/null 2>/dev/null; then
            git remote add "$git_backup_branch" "file:///dev/null"
            git remote set-url --push "$git_backup_branch" "$git_backup_root/$git_backup_name"
          fi

          git remote -v
        };
        f''; # notice the \n
    };
  };
}
