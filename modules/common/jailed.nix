{ pkgs, stdenvNoCC, ... }:

let
  lib = pkgs.lib;
  mkJailed =
    {
      originalPkg,
      profile,
      extraArgs ? [ ],
      withoutMan ? false,
      attr,
    }:
    let
      args = lib.escapeShellArgs (
        extraArgs ++ (lib.optional (profile != null) "--profile=${toString profile}")
      );
      overrideFuc =
        if builtins.hasAttr "overrideAttrs" originalPkg then "overrideAttrs" else "overrideDerivation";
    in
    if withoutMan then
      stdenvNoCC.mkDerivation {
        inherit (originalPkg)
          pname
          version
          ;
        dontBuild = true;
        dontUnpack = true;
        installPhase = ''
          runHook preInstall

          mkdir -p $out/bin
          for file in ${originalPkg}/bin/*; do
              if [ -f "$file" ] && [ -x "$file" ]; then
                  base="$(basename $file)"
                  cat > $out/bin/$base << EOF
          #! ${pkgs.runtimeShell} -e
          exec firejail ${args} -- $file "\$@"
          EOF
                  chmod +x $out/bin/$base
              fi
          done

          runHook postInstall
        '';
      }
    else
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
