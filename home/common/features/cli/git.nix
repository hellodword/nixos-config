{ pkgs, ... }:

let
  GIT_BACKUP_DIR = "$HOME/backups/git";
  GIT_BACKUP_REMOTE = "laptop-git-backup";
in
{
  programs.git = {
    enable = true;
    package = pkgs.gitFull;
    settings.core.editor = "vim";
    signing.format = "openpgp";
    settings.alias = {
      "config-github" =
        "!git config user.name hellodword && git config user.email 46193371+hellodword@users.noreply.github.com";
      "config-dependabot" =
        "!git config user.name dependabot[bot] && git config user.email 49699333+dependabot[bot]@users.noreply.github.com";
      "config-codex" = "!git config user.name Codex && git config user.email noreply@openai.com";
      "config-ai-codex" = "!git config --local ai.commitcoauthor Codex <noreply@openai.com>";
      "remote-add-github" =
        "!f() { git remote add origin git@hellodword.github.com:hellodword/$1.git; }; f";

      # push only https://stackoverflow.com/a/53706195
      "backup" = ''
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
          local BACKUP_ROOT="${GIT_BACKUP_DIR}"
          local BACKUP_REMOTE="${GIT_BACKUP_REMOTE}"

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
        f''; # notice the \n
    };
  };

  programs.starship = {
    settings = {
      custom = {
        git_backup_status = {
          command = ''[ -d "$(git remote get-url --push ${GIT_BACKUP_REMOTE})" ] || echo ❌❌❌ NOT BACKUP'';
          require_repo = true;
          when = true;
          ignore_timeout = true;
          style = "bold yellow";
        };
      };
    };
  };
}
