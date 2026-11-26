# CI manifest for laptop and remote scopes consumed by infra#ci.
{
  flake,
  system ? "x86_64-linux",
  select ? { },
}:
let
  scope = select.scope or "laptop";
  rawHost = select.hostName or (if scope == "laptop" then "laptop2" else "");
  hostName = if rawHost == "" then null else rawHost;
  remote = scope == "remote";
  pkgs = flake.inputs.${if remote then "nixpkgs-remote" else "nixpkgs"}.legacyPackages.${system};
  inherit (pkgs) lib;
  inherit (import ../infra/nix/ci.nix) mkManifest;
  checks = flake.checks.${system};
  allVMs = [
    "vm-network"
    "vm-desktop"
    "vm-applications"
    "vm-backup"
    "vm-files"
    "vm-vps"
  ];
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
          ]
          ++ allVMs
        ))
      ) (builtins.attrNames checks);
  products = {
    inherit (checks) lint;
    oranc = flake.packages.${system}.oranc;
    ci-tools = flake.inputs.infra.packages.${system}.ci-tools;
  }
  // (
    if remote then
      {
        dev-shell = flake.devShells.${system}.vps;
        inherit (flake.packages.${system}) wrangler;
      }
    else
      assert lib.assertMsg (hostName != null) "laptop CI scope requires select.hostName";
      {
        system = flake.nixosConfigurations.${hostName}.config.system.build.toplevel;
        dev-shell = flake.devShells.${system}.laptop;
      }
  );
in
assert
  builtins.elem scope [
    "laptop"
    "remote"
  ]
  || throw "CI scope must be laptop or remote";
mkManifest {
  buildName = "dependencies";
  build = products // lib.genAttrs checkNames (name: checks.${name});
  driverKvm = remote;
  driverGroupName = "vm-vps-driver";
  vmGroups =
    if remote then
      [
        {
          name = "vm-vps";
          checks = {
            inherit (checks) vm-vps;
          };
        }
      ]
    else
      [
        {
          name = "vm-network-backup";
          checks = {
            inherit (checks)
              vm-network
              vm-backup
              vm-files
              ;
          };
        }
        {
          name = "vm-desktop";
          checks = {
            inherit (checks) vm-desktop;
          };
        }
        {
          name = "vm-applications";
          checks = {
            inherit (checks) vm-applications;
          };
        }
      ];
  cacheIdentity = builtins.fromJSON (builtins.readFile ./cache-identity.json);
  cacheConfig = import ./cache-config.nix;
  cachePolicy = import ./cache-policy.nix { inherit flake hostName scope; };
  update =
    if remote then
      {
        targets = [
          {
            inputs = [
              "nixpkgs-remote"
              "colmena"
              "cloudflare-ips-v4"
              "cloudflare-ips-v6"
            ];
          }
        ];
        allowedLockfiles = [ "flake.lock" ];
        ignoreOnlyInputs = [ ];
        commitTitle = "chore: update remote flake inputs";
        branchPrefix = "automation/flake-update-remote";
      }
    else
      {
        targets = [
          {
            flake = "./infra";
            inputs = [ "nixpkgs" ];
          }
          {
            inputs = [
              "infra"
              "catppuccin-fcitx5"
              "nixos-hardware"
              "plasma-manager"
              "sing-box-geosite"
              "reproducible-violentmonkey"
              "arkenfox-userjs"
              "home-manager"
              "nix-index-database"
              "sing-box-geoip"
            ];
          }
        ];
        allowedLockfiles = [
          "flake.lock"
          "infra/flake.lock"
        ];
        ignoreOnlyInputs = [
          "sing-box-geosite"
          "sing-box-geoip"
        ];
        commitTitle = "chore: update laptop flake inputs";
        branchPrefix = "automation/flake-update-laptop";
      };
}
