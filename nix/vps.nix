{
  inputs,
  directory ?
    let
      cwd = builtins.getEnv "PWD";
    in
    if cwd == "" then "" else cwd + "/tmp/vps",
  metadata ? null,
}:
let
  inherit (inputs.nixpkgs-remote) lib;
  inventory =
    if metadata != null then
      metadata
    else if directory == "" || !(builtins.pathExists (directory + "/metadata.json")) then
      {
        nodes = { };
      }
    else
      builtins.fromJSON (builtins.readFile (directory + "/metadata.json"));
  nodeModules = name: node: [
    ../modules/vps/node.nix
    {
      networking.hostName = name;
      _module.args = {
        inherit node;
        vps = inventory;
      };
    }
  ];
  bootstrap = lib.mapAttrs (
    name: node:
    lib.nixosSystem {
      system = "x86_64-linux";
      modules = nodeModules name node;
    }
  ) inventory.nodes;
  hive = {
    meta.nixpkgs = inputs.nixpkgs-remote.legacyPackages.x86_64-linux;
  }
  // lib.mapAttrs (name: node: { ... }: {
    imports =
      nodeModules name node
      ++ [ ../modules/vps/proxy.nix ]
      ++ map (path: ../. + "/${path}") (node.modules or [ ]);
    deployment = {
      targetHost = node.sshHost;
      targetUser = null;
      targetPort = null;
      buildOnTarget = false;
      tags = node.tags or [ ];
      keys = lib.genAttrs [ "proxy.json" "certificate.json" ] (file: {
        keyFile = "${directory}/nodes/${name}/${node.release}/${file}";
        destDir = "/var/lib/site-vps/releases/${node.release}";
        permissions = "0600";
        uploadAt = "pre-activation";
      });
    };
  }) inventory.nodes;
in
{
  inherit bootstrap hive;
}
