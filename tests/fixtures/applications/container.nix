{ pkgs }:
let
  revision = pkgs.vscode.rev;
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
    mkdir -p $out/{bin,etc,usr,lib,lib64,root/.vscode-server/bin,tmp,workspaces}
    cp -rs ${tools}/bin/. $out/bin/
    ln -s /bin $out/usr/bin
    ln -s /lib $out/usr/lib
    ln -s ${pkgs.glibc}/lib/ld-linux-x86-64.so.2 $out/lib64/ld-linux-x86-64.so.2
    ln -s ${pkgs.glibc}/lib/libc.so.6 $out/lib/libc.so.6
    ln -s ${pkgs.stdenv.cc.cc.lib}/lib/libstdc++.so.6 $out/lib/libstdc++.so.6
    ln -s ${pkgs.stdenv.cc.cc.lib}/lib/libgcc_s.so.1 $out/lib/libgcc_s.so.1
    cp -r ${pkgs.vscode.vscodeServer} $out/root/.vscode-server/bin/${revision}
    printf 'root:x:0:0:root:/root:/bin/bash\n' > $out/etc/passwd
    printf 'root:x:0:\n' > $out/etc/group
    printf 'ID=debian\nVERSION_ID=12\nPRETTY_NAME="Synthetic development workspace"\n' > $out/etc/os-release
    chmod 1777 $out/tmp
  '';
in
pkgs.dockerTools.buildLayeredImage {
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
}
