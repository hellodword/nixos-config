# Derivations for the selected verification scope. YAML owns execution order.
{
  flake,
  scope,
  hostName ? null,
}:
let
  system = "x86_64-linux";
  remote = scope == "remote";
  pkgs = flake.inputs.${if remote then "nixpkgs-remote" else "nixpkgs"}.legacyPackages.${system};
  inherit (pkgs) lib;
  host = flake.nixosConfigurations.${hostName};
  checks = flake.checks.${system};
  allVMs = [
    "vm-network"
    "vm-desktop"
    "vm-applications"
    "vm-backup"
    "vm-vps"
  ];
  vmNames = if remote then [ "vm-vps" ] else lib.remove "vm-vps" allVMs;
  checkNames =
    if remote then
      [ "vps" ]
    else
      lib.filter (name: name != "e2e" && !(lib.elem name allVMs)) (builtins.attrNames checks);
  tools = import ./ci-tools.nix { inherit flake scope; };
  products = [
    flake.packages.${system}.oranc
    tools
  ]
  ++ (
    if remote then
      [
        flake.devShells.${system}.vps
        flake.packages.${system}.vps-python
        flake.packages.${system}.wrangler
      ]
    else
      [
        host.config.system.build.toplevel
        flake.devShells.${system}.laptop
      ]
  );
  aggregate = pkgs.linkFarm "${scope}-vm-tests" (
    map (name: {
      inherit name;
      path = checks.${name};
    }) vmNames
  );
  roots = products ++ map (name: checks.${name}) (checkNames ++ vmNames) ++ [ aggregate ];
  policy = import ./cache-policy.nix {
    inherit
      flake
      hostName
      scope
      roots
      ;
  };
  build = name: package: {
    inherit name;
    drv = package.drvPath;
    outputs = map (output: toString package.${output}) package.outputs;
  };
  vm = name: (build name checks.${name}) // { vm = true; };
in
assert lib.assertMsg (lib.elem scope [
  "laptop"
  "remote"
]) "CI scope must be laptop or remote";
(builtins.removeAttrs policy [ "privateBuilds" ])
// {
  inherit scope;
  builds = {
    private = policy.privateBuilds;
    dependencies =
      map (package: build (lib.getName package) package) products
      ++ map (name: build name checks.${name}) checkNames
      ++ map (name: build "${name}-driver" checks.${name}.driver) vmNames;
    vm-network-backup = lib.optionals (!remote) (
      map vm [
        "vm-network"
        "vm-backup"
      ]
    );
    vm-desktop = lib.optionals (!remote) [ (vm "vm-desktop") ];
    vm-applications = lib.optionals (!remote) [ (vm "vm-applications") ];
    vm-vps = lib.optionals remote [ (vm "vm-vps") ];
    aggregate = [ (build "${scope}-e2e" aggregate) ];
  };
}
