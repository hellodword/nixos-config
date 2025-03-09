{
  config,
  pkgs,
  persistPath,
  ...
}:

let
  originalPkg = pkgs.anytype;
  package = originalPkg.overrideAttrs (oldAttrs: {
    postInstall = ''
      mv $out/bin/anytype $out/bin/.anytype-unwrapped
      cat > $out/bin/anytype << EOF
      #! ${pkgs.runtimeShell} -e
      exec firejail --profile=${./anytype.profile} -- $out/bin/.anytype-unwrapped "\$@"
      EOF
      chmod +x $out/bin/anytype
    '';
  });
in
{
  home.packages = [ package ];

  me.allowedUnfreePkg = [
    originalPkg
    "anytype-heart"
  ];

  me.exitProcess = [ "anytype" ];

  home.persistence = {
    "${persistPath}${config.home.homeDirectory}".directories = [ ".config/anytype" ];
  };
}
