{ pkgs }:
{
  package,
  name ? pkgs.lib.getName package,
  executable ? name,
  runtime ? [ ],
  network ? false,
  project ? true,
  writable ? [ ],
  readable ? [ ],
  nix ? false,
  ssh ? false,
  worker ? false,
  database ? false,
  passEnvironment ? [ ],
}:
let
  runtimePackages = [
    package
    pkgs.bash
    pkgs.coreutils
    pkgs.cacert
    pkgs.tini
  ]
  ++ runtime;
  closure = pkgs.closureInfo { rootPaths = runtimePackages; };
  policy = pkgs.writeText "${name}-sandbox.json" (
    builtins.toJSON {
      inherit
        name
        network
        project
        writable
        readable
        nix
        ssh
        worker
        database
        passEnvironment
        ;
      command = "${package}/bin/${executable}";
      path = pkgs.lib.makeBinPath runtimePackages;
      closure = "${closure}/store-paths";
      shell = "${pkgs.bash}/bin/bash";
      init = "${pkgs.tini}/bin/tini";
      ca = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      nsswitch = pkgs.writeText "tool-nsswitch.conf" "passwd: files\ngroup: files\nhosts: files dns\n";
      bwrap = "${pkgs.bubblewrap}/bin/bwrap";
      git = "${pkgs.gitMinimal}/bin/git";
      stat = "${pkgs.coreutils}/bin/stat";
      tmpfiles = "${pkgs.systemd}/bin/systemd-tmpfiles";
    }
  );
in
pkgs.writeShellScriptBin name ''
  exec ${pkgs.python3}/bin/python3 ${../scripts/devtools/sandbox.py} ${policy} "$@"
''
