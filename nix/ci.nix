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
  checks = flake.checks.${system};
  allVMs = [
    "vm-network"
    "vm-desktop"
    "vm-applications"
    "vm-backup"
    "vm-files"
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
  drivers = builtins.listToAttrs (
    map (name: {
      name = "${name}-driver";
      value = checks.${name}.driver;
    }) vmNames
  );
  cacheIdentity = builtins.fromJSON (builtins.readFile ./cache-identity.json);
  cacheConfig = import ./cache-config.nix;
  cachePolicy = import ./cache-policy.nix { inherit flake hostName scope; };
in
assert
  builtins.elem scope [
    "laptop"
    "remote"
  ]
  || throw "CI scope must be laptop or remote";
{
  jobs = products // drivers // lib.genAttrs (checkNames ++ vmNames) (name: checks.${name});

  groups =
    if remote then
      [
        {
          name = "private";
          jobs = [ ];
          required = true;
          vm = null;
          kvm = false;
          maxJobs = 1;
        }
        {
          name = "dependencies";
          jobs = builtins.attrNames products ++ checkNames;
          required = true;
          vm = null;
          kvm = false;
          maxJobs = 1;
        }
        {
          name = "vm-vps-driver";
          jobs = [ "vm-vps-driver" ];
          required = true;
          vm = null;
          kvm = true;
          maxJobs = 1;
        }
        {
          name = "vm-vps";
          jobs = [ "vm-vps" ];
          required = true;
          vm = "nixos";
          kvm = true;
          maxJobs = 1;
        }
      ]
    else
      [
        {
          name = "private";
          jobs = [ ];
          required = true;
          vm = null;
          kvm = false;
          maxJobs = 1;
        }
        {
          name = "dependencies";
          jobs = builtins.attrNames products ++ checkNames ++ builtins.attrNames drivers;
          required = true;
          vm = null;
          kvm = false;
          maxJobs = 1;
        }
        {
          name = "vm-network-backup";
          jobs = [
            "vm-network"
            "vm-backup"
            "vm-files"
          ];
          required = true;
          vm = "nixos";
          kvm = true;
          maxJobs = 1;
        }
        {
          name = "vm-desktop";
          jobs = [ "vm-desktop" ];
          required = true;
          vm = "nixos";
          kvm = true;
          maxJobs = 1;
        }
        {
          name = "vm-applications";
          jobs = [ "vm-applications" ];
          required = true;
          vm = "nixos";
          kvm = true;
          maxJobs = 1;
        }
      ];

  cache = {
    registry = cacheIdentity.registry or "ghcr.io";
    inherit (cacheIdentity) repository publicKey;
    mode = "incremental";
    targetUri = cacheConfig.ci.uri;
    readSubstituters = cacheConfig.ci.settings.substituters;
    trustedPublicKeys = cacheConfig.ci.settings.trusted-public-keys;
    inherit (cachePolicy)
      excludedPaths
      excludedDerivations
      bundles
      privateBuilds
      ;
  };

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
