let
  flakeConfig = (import ../flake.nix).nixConfig;
  publicSettings = {
    substituters = flakeConfig.extra-substituters;
    trusted-public-keys = flakeConfig.extra-trusted-public-keys;
    require-sigs = true;
  };
  project = (builtins.fromJSON (builtins.readFile ./cache-identity.json)) // {
    listenAddress = "172.17.0.1";
    port = 37515;
  };
  render = settings: ''
    extra-substituters = ${builtins.concatStringsSep " " settings.substituters}
    extra-trusted-public-keys = ${builtins.concatStringsSep " " settings.trusted-public-keys}
    require-sigs = true
  '';
  withProject =
    {
      repository,
      publicKey,
      listenAddress,
      port,
      registry ? "ghcr.io",
      ...
    }:
    let
      host = if builtins.match ".*:.*" listenAddress != null then "[${listenAddress}]" else listenAddress;
      listen = "${host}:${toString port}";
      uri = "http://${listen}/${registry}/${repository}";
      settings = publicSettings // {
        substituters = publicSettings.substituters ++ [ uri ];
        trusted-public-keys = publicSettings.trusted-public-keys ++ [ publicKey ];
      };
    in
    {
      inherit listen uri settings;
      text = render settings;
    };
in
{
  inherit project publicSettings withProject;
  public.text = render publicSettings;
  local = withProject project;
  ci = withProject (project // { listenAddress = "127.0.0.1"; });
}
