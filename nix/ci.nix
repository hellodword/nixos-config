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
      lib.filter (
        name:
        !(lib.elem name (
          [
            "e2e"
            "lint"
            "vm-files"
          ]
          ++ allVMs
        ))
      ) (builtins.attrNames checks);
  tools = import ./ci-tools.nix { inherit flake scope; };
  products = {
    inherit (checks) lint;
    oranc = flake.packages.${system}.oranc;
    ci-tools = tools;
  }
  // (
    if remote then
      {
        dev-shell = flake.devShells.${system}.vps;
        inherit (flake.packages.${system}) wrangler;
      }
    else
      {
        system = host.config.system.build.toplevel;
        dev-shell = flake.devShells.${system}.laptop;
      }
  );
  drivers = builtins.listToAttrs (
    map (name: {
      name = "${name}-driver";
      value = checks.${name}.driver;
    }) vmNames
  );
in
assert lib.assertMsg (lib.elem scope [
  "laptop"
  "remote"
]) "CI scope must be laptop or remote";
{
  # Listing groups does not force the system or test derivations. Each job is
  # evaluated independently by nix-eval-jobs before Python assembles the manifest.
  jobs = products // drivers // lib.genAttrs (checkNames ++ vmNames) (name: checks.${name});
  groups = {
    dependencies = builtins.attrNames products ++ checkNames ++ builtins.attrNames drivers;
    vm-network-backup = lib.optionals (!remote) [
      "vm-network"
      "vm-backup"
    ];
    vm-desktop = lib.optionals (!remote) [ "vm-desktop" ];
    vm-applications = lib.optionals (!remote) [ "vm-applications" ];
    vm-vps = lib.optionals remote [ "vm-vps" ];
  };
  policy = import ./cache-policy.nix { inherit flake hostName scope; };
}
