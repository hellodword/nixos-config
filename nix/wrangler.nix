{ pkgs }:
import ./tool-sandbox.nix { inherit pkgs; } {
  name = "wrangler";
  package = pkgs.wrangler;
  runtime = [ pkgs.nodejs ];
  network = true;
  project = false;
  worker = true;
}
