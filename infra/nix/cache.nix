# Shared signed OCI cache configuration renderer and redistribution policy builder.
let
  basePublic = import ./public-caches.nix;

  dedupe =
    list: builtins.foldl' (acc: item: if builtins.elem item acc then acc else acc ++ [ item ]) [ ] list;

  formatHost = address: if builtins.match ".*:.*" address != null then "[${address}]" else address;

  normalizeRepo =
    repo:
    {
      registry = "ghcr.io";
    }
    // repo;

  renderClientFragment =
    {
      substituters,
      trustedPublicKeys,
      optionalInclude ? null,
    }:
    ''
      extra-substituters = ${builtins.concatStringsSep " " substituters}
      extra-trusted-public-keys = ${builtins.concatStringsSep " " trustedPublicKeys}
      require-sigs = true
    ''
    + (if optionalInclude != null then "!include ${optionalInclude}\n" else "");

  renderDaemonConf =
    {
      substituters,
      trustedPublicKeys,
      optionalInclude ? null,
      trustedUsers ? [
        "root"
        "vscode"
      ],
    }:
    ''
      experimental-features = nix-command flakes
      extra-experimental-features = nix-command flakes
      sandbox = true
      sandbox-fallback = true
      require-sigs = true
      trusted-users = ${builtins.concatStringsSep " " trustedUsers}
      substituters = ${builtins.concatStringsSep " " substituters}
      trusted-public-keys = ${builtins.concatStringsSep " " trustedPublicKeys}
    ''
    + (if optionalInclude != null then "!include ${optionalInclude}\n" else "");

  mkCacheConfig =
    {
      target ? null,
      extraRepositories ? [ ],
      listenAddress ? "172.17.0.1",
      ciListenAddress ? "127.0.0.2",
      port ? 37515,
      optionalInclude ? null,
      publicDefaults ? basePublic,
    }:
    let
      normalizedTarget = if target == null then null else normalizeRepo target;
      normalizedExtras = map normalizeRepo extraRepositories;
      allRepos = normalizedExtras ++ (if normalizedTarget != null then [ normalizedTarget ] else [ ]);

      allTrustedKeys = dedupe (publicDefaults.trusted-public-keys ++ map (repo: repo.publicKey) allRepos);

      publicSettings = {
        substituters = dedupe publicDefaults.substituters;
        trusted-public-keys = allTrustedKeys;
        require-sigs = true;
      };

      mkProxyScope =
        addr:
        let
          clientAddr =
            if addr == "0.0.0.0" then
              "127.0.0.1"
            else if addr == "::" then
              "::1"
            else
              addr;
          listen = "${formatHost addr}:${toString port}";
          clientEndpoint = "${formatHost clientAddr}:${toString port}";
          uriFor = repo: "http://${clientEndpoint}/${repo.registry}/${repo.repository}";
          uris = dedupe (map uriFor allRepos);
          uri =
            if normalizedTarget != null then
              uriFor normalizedTarget
            else if uris != [ ] then
              builtins.head uris
            else
              null;
          substituters = dedupe (publicDefaults.substituters ++ uris);
          settings = {
            inherit substituters;
            trusted-public-keys = allTrustedKeys;
            require-sigs = true;
            fallback = true;
            connect-timeout = 5;
          };
          proxyFragment = ''
            extra-substituters = ${builtins.concatStringsSep " " uris}
            fallback = true
            connect-timeout = 3
          '';
        in
        {
          inherit
            listen
            uri
            uris
            settings
            proxyFragment
            ;
          text = renderClientFragment {
            inherit substituters;
            trustedPublicKeys = allTrustedKeys;
          };
        };
    in
    {
      target = normalizedTarget;
      extraRepositories = normalizedExtras;
      public = {
        settings = publicSettings;
        text = renderClientFragment {
          substituters = publicSettings.substituters;
          trustedPublicKeys = allTrustedKeys;
          inherit optionalInclude;
        };
        daemonConf = renderDaemonConf {
          substituters = publicSettings.substituters;
          trustedPublicKeys = allTrustedKeys;
          inherit optionalInclude;
        };
      };
      local = mkProxyScope listenAddress;
      ci = mkProxyScope ciListenAddress;
    };

  mkPolicy =
    {
      lib,
      flakeOutPath,
      candidates ? [ ],
      extraRestricted ? [ ],
      extraExcluded ? [ ],
      bundles ? [ ],
      extraPrivateBuilds ? [ ],
    }:
    let
      isRestricted =
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

      outputsOf = package: map (name: toString package.${name}) (package.outputs or [ "out" ]);

      packagePaths =
        package:
        outputsOf package ++ lib.optional (package ? src && package.src != null) (toString package.src);

      uniqueByDrv =
        pkgsList:
        builtins.foldl' (
          acc: pkg:
          if lib.isDerivation pkg && !(builtins.any (existing: existing.drvPath == pkg.drvPath) acc) then
            acc ++ [ pkg ]
          else
            acc
        ) [ ] pkgsList;

      explicitRestricted = lib.concatMap unwrap extraRestricted;
      explicitRestrictedDrvs = map (package: package.drvPath) explicitRestricted;

      explicitExcluded = lib.concatMap unwrap extraExcluded;
      explicitExcludedDrvs = map (package: package.drvPath) explicitExcluded;

      hasRestrictedLayer =
        package:
        lib.any (layer: isRestricted layer || builtins.elem layer.drvPath explicitRestrictedDrvs) (
          unwrap package
        );

      hasExcludedLayer =
        package: lib.any (layer: builtins.elem layer.drvPath explicitExcludedDrvs) (unwrap package);

      restrictedPackages = uniqueByDrv (
        (lib.concatMap (package: lib.optionals (hasRestrictedLayer package) (unwrap package)) candidates)
        ++ explicitRestricted
      );

      excludedPackages = uniqueByDrv (
        restrictedPackages
        ++ (lib.concatMap (package: lib.optionals (hasExcludedLayer package) (unwrap package)) candidates)
        ++ explicitExcluded
      );
    in
    {
      excludedPaths = lib.unique (
        [ (toString flakeOutPath) ] ++ lib.concatMap packagePaths excludedPackages
      );
      excludedDerivations = lib.unique (map (package: package.drvPath) excludedPackages);
      inherit bundles;
      privateBuilds = map (package: {
        name = lib.getName package;
        drv = package.drvPath;
        outputs = outputsOf package;
      }) (uniqueByDrv (restrictedPackages ++ extraPrivateBuilds));
    };
in
{
  publicSettings = basePublic // {
    require-sigs = true;
  };
  inherit mkCacheConfig mkPolicy;
}
