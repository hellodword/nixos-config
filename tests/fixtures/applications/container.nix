{ pkgs }:
let
  # Upstream nixpkgs 1.146 bumped VS Code without updating rev / vscodeServer;
  # align to 1.146.0's product.json commit and verify commit parity at build time.
  staleUpstreamRev =
    pkgs.vscode.version == "1.146" && pkgs.vscode.rev == "2c33b50b16c472efe58357d1d2a8a5414bc23fbf";
  revision = if staleUpstreamRev then "69047191fc427f2f92828279aae1d90d8eeda7ab" else pkgs.vscode.rev;
  vscodeServer =
    if staleUpstreamRev then
      pkgs.srcOnly {
        name = "vscode-server-${revision}.tar.gz";
        src = pkgs.fetchurl {
          name = "vscode-server-${revision}.tar.gz";
          url = "https://update.code.visualstudio.com/commit:${revision}/server-linux-x64/stable";
          hash = "sha256-bCfY80JvKcMhYJ9rSZoySSTKLxcLi7Cy34IV8R6E/ZE=";
        };
        stdenv = pkgs.stdenvNoCC;
      }
    else
      pkgs.vscode.vscodeServer;
  tools = pkgs.buildEnv {
    name = "development-container-tools";
    paths = with pkgs; [
      bashInteractive
      coreutils
      glibc.bin
      findutils
      gnugrep
      gnused
      gnutar
      gzip
      curl
      git
      procps
      util-linux
      which
      shadow
    ];
    pathsToLink = [ "/bin" ];
  };
  root = pkgs.runCommand "development-container-root" { } ''
    expected_commit="$(${pkgs.jq}/bin/jq -r .commit ${pkgs.vscode}/lib/vscode/resources/app/product.json)"
    if [ "$expected_commit" != "${revision}" ]; then
      echo "VS Code server revision ${revision} does not match product.json commit $expected_commit" >&2
      exit 1
    fi
    mkdir -p $out/{bin,etc,usr,lib,lib64,root/.vscode-server/bin,tmp,workspaces}
    cp -rs ${tools}/bin/. $out/bin/
    ln -s /bin $out/usr/bin
    ln -s /lib $out/usr/lib
    ln -s ${pkgs.glibc}/lib/ld-linux-x86-64.so.2 $out/lib64/ld-linux-x86-64.so.2
    ln -s ${pkgs.glibc}/lib/libc.so.6 $out/lib/libc.so.6
    ln -s ${pkgs.stdenv.cc.cc.lib}/lib/libstdc++.so.6 $out/lib/libstdc++.so.6
    ln -s ${pkgs.stdenv.cc.cc.lib}/lib/libgcc_s.so.1 $out/lib/libgcc_s.so.1
    cp -r ${vscodeServer} $out/root/.vscode-server/bin/${revision}
    printf 'root:x:0:0:root:/root:/bin/bash\n' > $out/etc/passwd
    printf 'root:x:0:\n' > $out/etc/group
    printf 'ID=debian\nVERSION_ID=12\nPRETTY_NAME="Synthetic development workspace"\n' > $out/etc/os-release
    chmod 1777 $out/tmp
  '';
  image = pkgs.dockerTools.buildLayeredImage {
    name = "workspace-fixture";
    tag = "locked";
    contents = [ root ];
    config = {
      Env = [
        "PATH=/bin"
        "HOME=/root"
        "SHELL=/bin/bash"
        "LANG=C.UTF-8"
        "LC_ALL=C.UTF-8"
        "LD_LIBRARY_PATH=/lib"
      ];
      Cmd = [
        "/bin/sleep"
        "infinity"
      ];
      WorkingDir = "/workspaces/project";
    };
  };
in
image
// {
  passthru = (image.passthru or { }) // {
    inherit vscodeServer;
  };
}
