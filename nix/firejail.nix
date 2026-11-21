{ pkgs }:
{
  package,
  binaries,
  optionalBinaries ? [ ],
  profile,
  arguments ? [ ],
}:
let
  wrapBinary = binary: ''
    rm "$out/bin/${binary}"
    printf '%s\n' \
      '#!${pkgs.runtimeShell}' \
      'exec /run/wrappers/bin/firejail --quiet --profile=${profile} -- ${package}/bin/${binary} ${pkgs.lib.escapeShellArgs arguments} "$@"' \
      > "$out/bin/${binary}"
    chmod +x "$out/bin/${binary}"
  '';
in
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
    ${pkgs.lib.concatMapStringsSep "\n" wrapBinary binaries}
    ${pkgs.lib.concatMapStringsSep "\n" (binary: ''
      if [[ -e "$out/bin/${binary}" || -L "$out/bin/${binary}" ]]; then
        ${wrapBinary binary}
      fi
    '') optionalBinaries}
    python3 ${../scripts/desktop/sandbox_desktop.py} "$out" ${package} ${
      pkgs.lib.escapeShellArgs (binaries ++ optionalBinaries)
    }
  '';
}
