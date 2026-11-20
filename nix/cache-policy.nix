# Publication policy for the products selected by ci.nix.
{
  flake,
  hostName,
  scope,
}:
let
  system = "x86_64-linux";
  inherit (flake.inputs.nixpkgs) lib;
  restricted =
    package:
    lib.isDerivation package
    && lib.any (license: !(license.redistributable or true)) (lib.toList (package.meta.license or [ ]));
  unwrap =
    package:
    let
      inner = package.passthru.unwrapped or (package.unwrapped or null);
    in
    lib.optionals (lib.isDerivation package) (
      [ package ]
      ++ lib.optionals (inner != null && lib.isDerivation inner && inner.drvPath != package.drvPath) (
        unwrap inner
      )
    );
  outputs = package: map (name: toString package.${name}) (package.outputs or [ "out" ]);
  packagePaths =
    package:
    outputs package ++ lib.optional (package ? src && package.src != null) (toString package.src);
  policyFor =
    {
      candidates,
      extraRestricted ? [ ],
      extraExcluded ? [ ],
      bundles ? [ ],
      extraPrivateBuilds ? [ ],
    }:
    let
      packages = lib.unique (
        (lib.filter restricted (lib.concatMap unwrap candidates)) ++ (lib.concatMap unwrap extraRestricted)
      );
      excludedPackages = lib.unique (packages ++ (lib.concatMap unwrap extraExcluded));
    in
    {
      excludedPaths = lib.unique (
        [ (toString flake.outPath) ] ++ lib.concatMap packagePaths excludedPackages
      );
      excludedDerivations = lib.unique (map (package: package.drvPath) excludedPackages);
      inherit bundles;
      privateBuilds = map (package: {
        name = lib.getName package;
        drv = package.drvPath;
        outputs = outputs package;
      }) (packages ++ extraPrivateBuilds);
    };
in
if scope == "remote" then
  let
    remotePkgs = flake.inputs.nixpkgs-remote.legacyPackages.${system};
    devShell = flake.devShells.${system}.vps;
    vpsTools = (import ../profiles/vps/tools.nix { pkgs = remotePkgs; }).environment.systemPackages;
  in
  policyFor {
    candidates =
      vpsTools
      ++ (devShell.nativeBuildInputs or [ ])
      ++ (devShell.buildInputs or [ ])
      ++ [
        flake.packages.${system}.oranc
        flake.packages.${system}.wrangler
      ];
  }
else
  let
    host = flake.nixosConfigurations.${hostName};
    inherit (host) pkgs;
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
    devShell = flake.devShells.${system}.laptop;
    image = import ../tests/fixtures/applications/container.nix { inherit pkgs; };
  in
  policyFor {
    candidates =
      (lib.concatMap (config: config.environment.systemPackages) configurations)
      ++ (lib.concatMap (home: home.home.packages) homes)
      ++ extensions
      ++ (devShell.nativeBuildInputs or [ ])
      ++ (devShell.buildInputs or [ ]);
    # Wrapped applications, companion daemons and the editor's container server have separate payloads.
    extraRestricted = [
      pkgs.anytype
      pkgs.anytype-heart
      pkgs.google-chrome
    ]
    ++ lib.concatMap (
      home:
      lib.optionals home.programs.vscode.enable [
        home.programs.vscode.package
        home.programs.vscode.package.vscodeServer
      ]
    ) homes;
    extraExcluded = [
      pkgs.vscode
      pkgs.vscode.vscodeServer
    ];
    # Image layers embed restricted files. System symlinks and test results do not.
    bundles = [ image.drvPath ];
    extraPrivateBuilds = [ image ];
  }
