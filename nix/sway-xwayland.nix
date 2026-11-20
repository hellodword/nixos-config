{ pkgs }:
let
  inherit (pkgs) lib;
  # Sway uses XWayland and the system Fcitx GTK module until packaged Electron
  # builds include Chromium 158 commit 564344ab9eb89b305366e60b4b4f8ab2f70e791c,
  # which guards null xkb_state_ in XkbKeyboardLayoutEngine on early IM focus.
  run = lib.escapeShellArg ''
    case ":''${XDG_CURRENT_DESKTOP:-}:" in
      *:sway:*)
        unset NIXOS_OZONE_WL
        export GTK_IM_MODULE=fcitx
        export GTK_IM_MODULE_FILE=/run/current-system/sw/etc/gtk-3.0/immodules.cache
        set -- --ozone-platform=x11 "$@"
        ;;
    esac
  '';
in
{
  package,
  binary,
}:
pkgs.symlinkJoin {
  name = "${package.name}-sway";
  inherit (package) pname version meta;
  passthru = (package.passthru or { }) // {
    unwrapped = package;
  };
  paths = [ package ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    wrapProgram "$out/bin/${binary}" --run ${run}
  '';
}
