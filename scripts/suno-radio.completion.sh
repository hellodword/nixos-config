#
# Installation:
#
# Via shell config file  ~/.bashrc  (or ~/.zshrc)
#
#   Append the contents to config file
#   'source' the file in the config file
#
# You may also have a directory on your system that is configured
#    for completion files, such as:
#
#    /usr/local/etc/bash_completion.d/

###-begin-suno-completion-###

if type complete &>/dev/null; then
  __suno_completion() {
    local current_word="''${COMP_WORDS[COMP_CWORD]}"

    local options="status trending weekly monthly top"

    if [[ "$COMP_CWORD" -eq 1 ]]; then
        COMPREPLY=( $(compgen -W "$options" -- "$current_word") )
        return 0
    fi

    if [[ "$COMP_CWORD" -eq 2 ]]; then
        COMPREPLY=( $(compgen -W "$options" -- "$current_word") )
        return 0
    fi
  }
  complete -F __suno_completion suno-radio
fi

###-end-suno-completion-###
