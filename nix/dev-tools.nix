# Isolated development-shell command policies shared across shells and VM scenarios.
# Network engines, linters, and cache tools run inside Bubblewrap namespaces via
# tool-sandbox.nix so untrusted or complex parsers cannot read the host home
# directory, SSH agent, or decrypted credential files directly.
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
    package = inputs.infra.packages.${system}.oranc;
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
