# Publication inventory for one host and the common test fixtures.
{ flake, hostName }:
let
  system = "x86_64-linux";
  host = flake.nixosConfigurations.${hostName};
  inherit (host) pkgs;
  inherit (pkgs) lib;
  fixture = flake.inputs.nixpkgs.lib.nixosSystem {
    modules = [
      ../modules
      ../tests/fixtures/laptop.nix
    ];
    specialArgs = {
      inputs = flake.inputs // {
        self = flake;
      };
      userName = "fixture";
    };
  };
  configurations = [
    host.config
    fixture.config
  ];
  homes = lib.concatMap (config: builtins.attrValues config.home-manager.users) configurations;
  extensions = lib.concatMap (
    home:
    lib.concatMap (profile: profile.extensions) (builtins.attrValues home.programs.vscode.profiles)
  ) homes;
  restricted =
    package:
    lib.any (license: !(license.redistributable or true)) (lib.toList (package.meta.license or [ ]));
  packages = lib.unique (
    lib.filter restricted (
      (lib.concatMap (config: config.environment.systemPackages) configurations)
      ++ (lib.concatMap (home: home.home.packages) homes)
      ++ extensions
    )
    # Wrapped applications and the editor's container server have separate payloads.
    ++ [ pkgs.google-chrome ]
    ++ lib.concatMap (
      home:
      lib.optionals home.programs.vscode.enable [
        home.programs.vscode.package
        home.programs.vscode.package.vscodeServer
      ]
    ) homes
  );
  image = import ../tests/fixtures/applications/container.nix { inherit pkgs; };
  outputs = package: map (name: toString package.${name}) package.outputs;
  roots = [
    host.config.system.build.toplevel
    flake.devShells.${system}.default
    flake.packages.${system}.oranc
  ]
  ++ builtins.attrValues flake.checks.${system};
in
{
  roots = map (package: package.drvPath) roots;
  excludedPaths = lib.unique (
    lib.concatMap (
      package: outputs package ++ lib.optional (package ? src) (toString package.src)
    ) packages
  );
  excludedDerivations = map (package: package.drvPath) packages;
  # Image layers embed restricted files. System symlinks and test results do not.
  bundles = [ image.drvPath ];
  privateBuilds = map (package: {
    name = lib.getName package;
    drv = package.drvPath;
    outputs = outputs package;
  }) (packages ++ [ image ]);
}
