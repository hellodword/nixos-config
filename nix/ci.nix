# Derivations for the workflow's named steps. YAML owns their execution order.
{ flake, hostName }:
let
  system = "x86_64-linux";
  host = flake.nixosConfigurations.${hostName};
  inherit (host.pkgs) lib;
  checks = flake.checks.${system};
  policy = import ./cache-policy.nix { inherit flake hostName; };
  build = name: package: {
    inherit name;
    drv = package.drvPath;
    outputs = map (output: toString package.${output}) package.outputs;
  };
  vm = name: (build name checks.${name}) // { vm = true; };
  vmNames = [
    "vm-network"
    "vm-desktop"
    "vm-applications"
    "vm-backup"
  ];
in
(builtins.removeAttrs policy [ "privateBuilds" ])
// {
  builds = {
    private = policy.privateBuilds;
    dependencies = [
      (build "${hostName}-system" host.config.system.build.toplevel)
      (build "development-shell" flake.devShells.${system}.default)
      (build "oranc" flake.packages.${system}.oranc)
    ]
    ++ map (name: build name checks.${name}) (
      lib.filter (name: name != "e2e" && !(lib.elem name vmNames)) (builtins.attrNames checks)
    )
    ++ map (name: build "${name}-driver" checks.${name}.driver) vmNames;
    vm-network-backup = map vm [
      "vm-network"
      "vm-backup"
    ];
    vm-desktop = [ (vm "vm-desktop") ];
    vm-applications = [ (vm "vm-applications") ];
    aggregate = [ (build "e2e" checks.e2e) ];
  };
}
