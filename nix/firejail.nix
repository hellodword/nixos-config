{ pkgs }:
{
  package,
  binaries,
  profile,
  arguments ? [ ],
}:
pkgs.symlinkJoin {
  name = "${pkgs.lib.getName package}-sandboxed";
  pname = pkgs.lib.getName package;
  version = pkgs.lib.getVersion package;
  paths = map (output: pkgs.lib.getOutput output package) (
    package.meta.outputsToInstall or [ "out" ]
  );
  nativeBuildInputs = [ pkgs.python3 ];
  meta = package.meta // {
    priority = -10;
    outputsToInstall = [ "out" ];
  };
  passthru.unwrapped = package;
  postBuild = ''
    ${pkgs.lib.concatMapStringsSep "\n" (binary: ''
        rm "$out/bin/${binary}"
        cat > "$out/bin/${binary}" <<'LAUNCHER'
      #!${pkgs.runtimeShell}
      exec /run/wrappers/bin/firejail --quiet --profile=${profile} -- ${package}/bin/${binary} ${pkgs.lib.escapeShellArgs arguments} "$@"
      LAUNCHER
        chmod +x "$out/bin/${binary}"
    '') binaries}
    python3 ${../scripts/desktop/sandbox_desktop.py} "$out" ${package} ${pkgs.lib.escapeShellArgs binaries}
  '';
}
