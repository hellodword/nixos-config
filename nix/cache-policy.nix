# Build phases and publication inventory for the system, development tools and tests.
{ flake }:
let
  system = "x86_64-linux";
  host = flake.nixosConfigurations.laptop2;
  inherit (host) pkgs;
  inherit (pkgs) lib;
  home = host.config.home-manager.users.ubuntu;
  extensions = lib.concatMap (profile: profile.extensions) (
    builtins.attrValues home.programs.vscode.profiles
  );
  restricted =
    package:
    lib.any (license: !(license.redistributable or true)) (lib.toList (package.meta.license or [ ]));
  packages = lib.unique (
    lib.filter restricted (host.config.environment.systemPackages ++ home.home.packages ++ extensions)
    # The sandbox wrapper and the VS Code server have separate store payloads.
    ++ [
      pkgs.google-chrome
      home.programs.vscode.package
      home.programs.vscode.package.vscodeServer
    ]
  );
  image = import ../tests/fixtures/applications/container.nix { inherit pkgs; };
  outputs = package: map (name: toString package.${name}) package.outputs;
  roots = [
    flake.checks.${system}.e2e
    flake.devShells.${system}.default
    flake.devShells.${system}.vm
    flake.packages.${system}.oranc
  ];
  checks = flake.checks.${system};
  build = name: package: {
    inherit name;
    drv = package.drvPath;
    outputs = outputs package;
  };
  vm = name: (build name checks.${name}) // { vm = true; };
  vmNames = [
    "vm-network"
    "vm-desktop"
    "vm-applications"
    "vm-backup"
  ];
in
{
  roots = map (package: package.drvPath) roots;
  excludedPaths = lib.unique (
    lib.concatMap (
      package: outputs package ++ lib.optional (package ? src) (toString package.src)
    ) packages
  );
  excludedDerivations = map (package: package.drvPath) packages;
  # This image copies VS Code Server. Exclude its payload-bearing intermediates
  # too, while retaining ordinary system symlinks and successful test results.
  bundles = [ image.drvPath ];
  builds = {
    private = map (package: build (lib.getName package) package) (packages ++ [ image ]);
    dependencies = [
      (build "laptop2-system" host.config.system.build.toplevel)
      (build "laptop2-home" home.home.activationPackage)
      (build "development-shell" flake.devShells.${system}.default)
      (build "vm-tools-shell" flake.devShells.${system}.vm)
      (build "oranc" flake.packages.${system}.oranc)
    ]
    ++ map (name: build name checks.${name}) (
      lib.filter (name: name != "e2e" && !(lib.elem name vmNames)) (builtins.attrNames checks)
    )
    ++ map (name: build "${name}-driver" checks.${name}.driver) vmNames;
    vm-network-desktop = map vm [
      "vm-network"
      "vm-desktop"
    ];
    vm-applications-backup = map vm [
      "vm-applications"
      "vm-backup"
    ];
    aggregate = [ (build "e2e" checks.e2e) ];
  };
}
