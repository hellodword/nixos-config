# Construct CI manifests with automatic VM driver preparation and signed cache wiring.
let
  mkManifest =
    {
      buildName ? "build",
      build,
      vmGroups ? [ ],
      driverKvm ? false,
      driverGroupName ? "drivers",
      cacheConfig ? null,
      cacheIdentity ? null,
      cachePolicy ? null,
      update ? null,
    }:
    let
      vmEntries = builtins.concatMap (
        group:
        map (name: {
          inherit name;
          value = group.checks.${name};
        }) (builtins.attrNames group.checks)
      ) vmGroups;
      vmChecks = builtins.listToAttrs vmEntries;
      vmNames = map (entry: entry.name) vmEntries;
      drivers = builtins.listToAttrs (
        map (name: {
          name = "${name}-driver";
          value = vmChecks.${name}.driver;
        }) vmNames
      );
      driverJobs = map (name: {
        job = "${name}-driver";
        prepares = name;
      }) vmNames;
      identity =
        if cacheIdentity != null then
          cacheIdentity
        else if cacheConfig != null then
          cacheConfig.target
        else
          null;
    in
    {
      jobs = build // drivers // vmChecks;
      groups = [
        {
          name = buildName;
          jobs = builtins.attrNames build ++ (if driverKvm then [ ] else driverJobs);
          required = true;
          vm = null;
          kvm = false;
          maxJobs = 1;
        }
      ]
      ++ (
        if driverKvm && driverJobs != [ ] then
          [
            {
              name = driverGroupName;
              jobs = driverJobs;
              required = true;
              vm = null;
              kvm = true;
              maxJobs = 1;
            }
          ]
        else
          [ ]
      )
      ++ map (group: {
        inherit (group) name;
        jobs = builtins.attrNames group.checks;
        required = group.required or true;
        vm = "nixos";
        kvm = true;
        maxJobs = group.maxJobs or 1;
      }) vmGroups;
      cache =
        if cacheConfig == null || cachePolicy == null || identity == null then
          null
        else
          {
            registry = identity.registry or "ghcr.io";
            inherit (identity) repository publicKey;
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
      inherit update;
    };
in
{
  inherit mkManifest;
}
