{
  config,
  pkgs,
  ...
}:
let
  vmSopsFixture =
    pkgs.runCommand "vm-sops-fixture"
      {
        nativeBuildInputs = [
          pkgs.age
          pkgs.sops
        ];
      }
      ''
        mkdir -p "$out"
        age-keygen -o "$out/keys.txt" 2>"$out/pubkey.log"
        recipient="$(sed -n 's/^# public key: //p' "$out/keys.txt")"
        printf 'smoke: synthetic-sops-ready\n' > "$out/plain.yaml"
        sops --encrypt --age "$recipient" --input-type yaml --output-type yaml "$out/plain.yaml" > "$out/smoke.sops.yaml"
        rm "$out/plain.yaml"
      '';
  keyDestination = "${config.site.storage.persistRoot}/var/lib/sops-nix/keys.txt";
in
{
  imports = [
    ../../modules/core/storage.nix
    ../../modules/core/base.nix
  ];
  site.core.enable = true;
  system.activationScripts.vmSopsKey.text = ''
    install -d -m 0700 "$(dirname ${pkgs.lib.escapeShellArg keyDestination})"
    install -m 0600 ${vmSopsFixture}/keys.txt ${pkgs.lib.escapeShellArg keyDestination}
  '';
  system.activationScripts.setupSecrets.deps = [ "vmSopsKey" ];
  sops.secrets.vm-smoke = {
    sopsFile = "${vmSopsFixture}/smoke.sops.yaml";
    key = "smoke";
  };
}
