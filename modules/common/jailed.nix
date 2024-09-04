{ pkgs, ... }:

let
  lib = pkgs.lib;
  mkJailed =
    {
      originalPkg,
      profile,
      extraArgs ? [ ],
    }:
    let
      name = originalPkg.drvAttrs.name;
      args = lib.escapeShellArgs (
        extraArgs ++ (lib.optional (profile != null) "--profile=${toString profile}")
      );
      outputs =
        if (lib.hasAttr "outputs" originalPkg) then
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
        set -x

        function write_bin {
            local bin="$1"
            local name="$(basename "$bin")"
            cat <<_EOF >$out/bin/"$name"
        #! ${pkgs.runtimeShell} -e
        exec /run/wrappers/bin/firejail ${args} -- "$bin" "\$@"
        _EOF
        chmod 0755 $out/bin/"$name"
        }

        function sync_dir {
          local source="$1"
          local target="$2"

          mkdir -p "$target"

          echo target "$target" source "$source"

          for entry in "$source"/*; do
            if [ -d "$entry" ]; then
              if [ -L "$entry" ]; then
                  cp -r --preserve=links "$entry" "$target/$(basename "$entry")"
              else
                  sync_dir "$entry" "$target/$(basename "$entry")"
              fi
            elif [ -f "$entry" ]; then
                if [[ "$(dirname "$entry")" == *"/bin" ]]; then
                    write_bin "$entry"
                else
                    ln -s "$entry" "$target/$(basename "$entry")"
                fi
            fi
          done
        }

        mkdir -p $out/bin

        ${lib.concatStringsSep "\n" (
          map (output: ''
            if [ -d "${output}" ]; then
                sync_dir "${output}" $out
            fi
          '') outputs
        )}
      '';
in
mkJailed
