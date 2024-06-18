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
          set -x

          [ -n "$1" ]

          [ -f "${GIT_BACKUP_DIR}/$1/HEAD" ] || git init --bare "${GIT_BACKUP_DIR}/$1"

          git remote set-url --delete origin "${GIT_BACKUP_DIR}/$1" 2>/dev/null || true
          git remote set-url --add origin "${GIT_BACKUP_DIR}/$1"

          git remote get-url "${GIT_BACKUP_BRANCH}" >/dev/null 2>/dev/null || \
            (git remote add "${GIT_BACKUP_BRANCH}" "file:///dev/null" && git remote set-url --push "${GIT_BACKUP_BRANCH}" "${GIT_BACKUP_DIR}/$1")

          git remote -v
        };
        f''; # notice the \n
    };
  };
}
