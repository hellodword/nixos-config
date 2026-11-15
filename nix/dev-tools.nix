# Command policies shared by the development shells and their VM scenarios.
{
  inputs,
  pkgs,
  system,
}:
let
  sandbox = import ./tool-sandbox.nix { inherit pkgs; };
  networkTool =
    name: package:
    sandbox {
      inherit name package;
      network = true;
      writable = [ "tmp/devtools/network" ];
    };
in
{
  sing-box = networkTool "sing-box" pkgs.sing-box;
  dnsdist = networkTool "dnsdist" pkgs.dnsdist;
  dnsproxy = networkTool "dnsproxy" pkgs.dnsproxy;
  dns-collector = networkTool "go-dnscollector" pkgs.dns-collector;
  actionlint = sandbox {
    package = pkgs.actionlint;
    runtime = [ pkgs.shellcheck ];
  };
  oranc = sandbox {
    name = "oranc";
    package = inputs.oranc.packages.${system}.oranc;
    network = true;
    nix = true;
    database = true;
    runtime = [ pkgs.nix ];
    writable = [ "tmp/devtools/cache" ];
    passEnvironment = [
      "ORANC_USERNAME"
      "ORANC_PASSWORD"
      "ORANC_SIGNING_KEY"
      "NIX_CONFIG"
    ];
  };
}
