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

###-begin-coderadio-completion-###

if type complete &>/dev/null; then
  __coderadio_completion() {
    local cur prev
    _init_completion || return

    case $prev in
        --interface)
            _available_interfaces -a
            return
            ;;
    esac

    if [[ $cur == -* ]]; then
        COMPREPLY=($(compgen -W '$(_parse_help "$1")' -- "$cur"))
    fi
  }
  complete -F __coderadio_completion coderadio
fi

###-end-coderadio-completion-###
