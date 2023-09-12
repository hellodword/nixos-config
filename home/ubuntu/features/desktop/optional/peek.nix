{ pkgs, nixosConfig, lib, ... }:

{
  home.file = lib.optionalAttrs nixosConfig.programs.firejail.enable {
    ".local/share/icons/hicolor/scalable/apps/com.uploadedlobster.peek.svg".source = "${pkgs.peek}/share/icons/hicolor/scalable/apps/com.uploadedlobster.peek.svg";
    ".local/share/icons/hicolor/symbolic/apps/com.uploadedlobster.peek-symbolic.svg".source = "${pkgs.peek}/share/icons/hicolor/symbolic/apps/com.uploadedlobster.peek-symbolic.svg";
  };

  home.packages = [
    (
      if nixosConfig.programs.firejail.enable then
        (builtins.elemAt
          (builtins.filter (x: x.meta.name == "firejail-wrapped-binaries") nixosConfig.environment.systemPackages)
          0)
      else
        pkgs.peek
    )
  ];
}
