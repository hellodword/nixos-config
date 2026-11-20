{ pkgs }:
let
  inherit (pkgs) lib;
  # Sway Wayland + Fcitx5 triggers an initialization race in Chromium < 158.0.8106.0:
  # Fcitx5 emits an IM activation event on first window focus before Sway delivers the
  # initial XKB keymap, causing XkbKeyboardLayoutEngine::UpdateModifiers() /
  # GetDomCodeByKeysym() to dereference a null xkb_state_ and crash with SIGSEGV in
  # xkb_state_update_mask() (Chromium Bug 558945735, fixed in commit
  # 564344ab9eb89b305366e60b4b4f8ab2f70e791c, earliest release 158.0.8106.0).
  #
  # Because Sway unsets GTK_IM_MODULE so native Wayland clients use zwp_text_input_v3,
  # routing Electron through XWayland (--ozone-platform=x11) must also export
  # GTK_IM_MODULE=fcitx and GTK_IM_MODULE_FILE so the X11 GTK3 Fcitx5 bridge loads
  # inside both host and Firejail environments.
  #
  # Retire per package only after inspecting the built binary (`strings ... | grep Chrome/`)
  # confirms Chrome >= 158.0.8106.0 (or an explicit nixpkgs backport) and vm-applications
  # passes on Sway under normal and CPU-contention runs.
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
