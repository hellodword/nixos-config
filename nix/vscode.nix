# Temporary overlay from https://github.com/NixOS/nixpkgs/pull/589900
# (generated with NixOS/nixpkgs#579073) so pkgs.vscode and pkgs.vscode.vscodeServer
# share commit 8a14f0cc1b08d531eb83255ea3764ae22aa932b5 (1.147.0).
# Remove this overlay once nixos-unstable includes VS Code >= 1.147.0.
final: prev: {
  vscode =
    if prev.lib.versionOlder prev.vscode.version "1.147.0" then
      let
        inherit (prev.stdenv.hostPlatform) system;
        throwSystem = throw "Unsupported system: ${system}";
        plat =
          {
            x86_64-linux = "linux-x64";
            aarch64-linux = "linux-arm64";
            aarch64-darwin = "darwin-arm64";
            armv7l-linux = "linux-armhf";
          }
          .${system} or throwSystem;
        archiveFmt = if prev.stdenv.hostPlatform.isDarwin then "zip" else "tar.gz";
        version = "1.147.0";
        rev = "8a14f0cc1b08d531eb83255ea3764ae22aa932b5";
        hash =
          {
            x86_64-linux = "sha256-b9ixRgDyqN24tIM9i/KI89xMNLKHjSxsP+x+FsgQI7w=";
            aarch64-linux = "sha256-sTf1Oimh3r+fwwAngjVWhjIC+UwQ2STdcPLSNweVQS0=";
            aarch64-darwin = "sha256-FJ2UT+tZmwdrSEBrF04cPNHVEOnWc4VHd6IKb0EWpZo=";
            armv7l-linux = "sha256-xrGh+yP9KZqlzatEHekW5D3pSy+2rhw+SN1dFuVeNjU=";
          }
          .${system} or throwSystem;
        vscodeServer = prev.srcOnly {
          name = "vscode-server-${rev}.tar.gz";
          src = prev.fetchurl {
            name = "vscode-server-${rev}.tar.gz";
            url = "https://update.code.visualstudio.com/commit:${rev}/server-linux-x64/stable";
            hash = "sha256-xohNMK4Db/S35uyqI7WaS5r/oyBC4BjPYfynKOU3Znw=";
          };
          stdenv = prev.stdenvNoCC;
        };
      in
      prev.vscode.overrideAttrs (old: {
        inherit version;
        src = prev.fetchurl {
          name = "VSCode_${version}_${plat}.${archiveFmt}";
          url = "https://update.code.visualstudio.com/${version}/${plat}/stable";
          inherit hash;
        };
        passthru = old.passthru // {
          vscodeVersion = version;
          inherit rev vscodeServer;
        };
        meta = old.meta // {
          changelog = "https://code.visualstudio.com/updates/v${
            prev.lib.replaceString "." "_" (prev.lib.versions.majorMinor version)
          }";
        };
      })
    else
      prev.vscode;
}
