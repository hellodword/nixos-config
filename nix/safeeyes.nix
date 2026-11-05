{ pkgs, hardening }:
let
  clientConfig = hardening // {
    RuntimeDirectory = "%N";
    RuntimeDirectoryMode = "0700";
    RuntimeMaxSec = "30s";
    Environment = [
      "HOME=%t/%N"
      "XDG_CONFIG_HOME=%h/.config"
      "XDG_CACHE_HOME=%t/%N/cache"
      "XDG_DATA_HOME=%t/%N/data"
      "GSK_RENDERER=cairo"
    ];
  };
  properties = pkgs.lib.mapAttrsToList (
    name: value:
    "--property=${name}="
    + (
      if builtins.isList value then
        pkgs.lib.concatStringsSep " " value
      else if builtins.isBool value then
        pkgs.lib.boolToString value
      else
        toString value
    )
  ) clientConfig;
  command = pkgs.writeShellApplication {
    name = "safeeyes";
    runtimeInputs = [
      pkgs.systemd
      pkgs.glib
    ];
    text = ''
      case "''${1:-}" in
        -h|--help|--version) ;;
        *)
          systemctl --user start safeeyes.service
          gdbus wait --session --timeout 30 io.github.slgobinath.SafeEyes
          ;;
      esac
      unit="safeeyes-control-$$"
      properties=( ${pkgs.lib.escapeShellArgs properties} )
      # Transient D-Bus properties take literal paths, unlike unit files.
      for index in "''${!properties[@]}"; do
        value="''${properties[index]//%h/$HOME}"
        value="''${value//%t/$XDG_RUNTIME_DIR}"
        properties[index]="''${value//%N/$unit}"
      done
      exec systemd-run --user --quiet --wait --pipe --collect --unit="$unit" \
        --expand-environment=no "''${properties[@]}" \
        ${pkgs.safeeyes}/bin/safeeyes "$@"
    '';
  };
in
pkgs.symlinkJoin {
  name = "safeeyes-session";
  paths = [ command ];
  meta.priority = -10;
  postBuild = ''
    mkdir -p "$out/share"
    ln -s ${pkgs.safeeyes}/${pkgs.python3.sitePackages}/safeeyes/platform/icons "$out/share/icons"
  '';
}
