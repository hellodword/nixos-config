# Host, container, and CI cache configuration rendered through infra.lib.cache.
let
  cacheLib = import ../infra/nix/cache.nix;
  identity = builtins.fromJSON (builtins.readFile ./cache-identity.json);
  project = identity // {
    listenAddress = "172.17.0.1";
    port = 37515;
  };
  hostStore = {
    listenAddress = project.listenAddress;
    port = 37516;
    priority = 20;
    uri = "http://${project.listenAddress}:37516";
  };
  withProject =
    {
      repository,
      publicKey,
      listenAddress ? "172.17.0.1",
      port ? 37515,
      registry ? "ghcr.io",
      extraRepositories ? [ ],
      publicDefaults ? cacheLib.publicSettings,
      ...
    }:
    (cacheLib.mkCacheConfig {
      target = {
        inherit registry repository publicKey;
      };
      inherit
        extraRepositories
        listenAddress
        port
        publicDefaults
        ;
    }).local;
  configured = cacheLib.mkCacheConfig {
    target = identity;
    listenAddress = project.listenAddress;
    ciListenAddress = "127.0.0.2";
    port = project.port;
  };
in
{
  inherit hostStore project withProject;
  publicSettings = cacheLib.publicSettings;
  inherit (configured) public local ci;
}
