{ pkgs, ... }:

let
  lib = pkgs.lib;
  mkJailed =
    {
      originalPkg,
      profile,
      extraArgs ? [ ],
      attr,
    }:
    let
      args = lib.escapeShellArgs (
        extraArgs ++ (lib.optional (profile != null) "--profile=${toString profile}")
      );
      overrideFuc =
        if builtins.hasAttr "overrideAttrs" originalPkg then "overrideAttrs" else "overrideDerivation";
    in
    originalPkg."${overrideFuc}" (oldAttrs: {
      ${attr} = ''
        ${if builtins.hasAttr attr oldAttrs then oldAttrs.${attr} else ""}

        for file in $out/bin/*; do
            if [ -f "$file" ] && [ -x "$file" ]; then
                dir="$(dirname $file)"
                base="$(basename $file)"
                mv $file $dir/.$base-unwrapped
                cat > $file << EOF
        #! ${pkgs.runtimeShell} -e
        exec firejail ${args} -- $dir/.$base-unwrapped "\$@"
        EOF
                chmod +x $file
            fi
        done
      '';
    });
in
mkJailed
