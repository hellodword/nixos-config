{ pkgs, ... }:

let
  lib = pkgs.lib;
  mkJailed = { originalPkg, profile, extraArgs ? [ ] }:
    let
      name =
        if
          (lib.hasAttr "pname" originalPkg)
        then
          originalPkg.pname
        else
          originalPkg.unwrapped.pname;
      args = lib.escapeShellArgs (
        extraArgs
        ++ (lib.optional (profile != null) "--profile=${toString profile}")
      );
      outputs =
        if
          (lib.hasAttr "outputs" originalPkg)
        then
          (map (x: originalPkg.${x}) originalPkg.outputs)
        else
          [ originalPkg ];
    in
    pkgs.runCommand "jailed-${name}"
      {
        preferLocalBuild = true;
        allowSubstitutes = false;
        # take precedence over non-firejailed versions
        meta.priority = -1;
      }
      ''
        mkdir -p $out/share
        mkdir -p $out/bin

        ${
          lib.concatStringsSep
          "\n"
          (
            map
            (
              output:
              ''
                if [ -d "${output}" ]; then
                    for file in "${output}"/*
                    do
                      if [[ "$file" == *"/share" ]]; then
                          ln -s "$file"/* $out/share
                      elif [[ "$file" == *"/bin" ]]; then
                          for bin in "$file"/*
                          do
                            if [ -f "$bin" ]; then
                                name="$(basename "$bin")"
                                cat <<_EOF >$out/bin/"$name"
                #! ${pkgs.runtimeShell} -e
                exec /run/wrappers/bin/firejail ${args} -- "$bin" "\$@"
                _EOF
                                chmod 0755 $out/bin/"$name"
                            else
                                ln -s "$bin" $out/bin
                            fi
                          done
                      else
                        ln -s "$file" $out
                      fi
                    done
                fi
              ''
            )
            outputs
          )
        }
      '';
in
mkJailed
