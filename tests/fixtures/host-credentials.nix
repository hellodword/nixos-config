{ pkgs, ... }:
let
  credentials =
    pkgs.runCommand "synthetic-host-credentials"
      {
        nativeBuildInputs = [
          (pkgs.python3.withPackages (p: [ p.pyyaml ]))
          pkgs.age
          pkgs.sops
          pkgs.gnupg
        ];
      }
      ''
        mkdir -p $out
        cp ${./gpg_identity.py} gpg_identity.py
        python3 - <<'PY'
        import os, subprocess
        from pathlib import Path
        import yaml
        import gpg_identity

        root = Path.cwd()
        key = root / "age.key"
        subprocess.run(["age-keygen", "-o", str(key)], check=True, capture_output=True)
        recipient = subprocess.check_output(["age-keygen", "-y", str(key)], text=True).strip()
        home = root / "gpg"
        home.mkdir(mode=0o700)
        try:
            identity, _ = gpg_identity.create(home, root / "identity")
            system = yaml.safe_load(Path("${../../data/secrets/system.example.yaml}").read_text())
            system["login"]["passwordHash"] = "!"
            system["tailscale"]["authKey"] = "synthetic-tailscale-key"
            system["notifications"] = {"barkDeviceToken": "synthetic-device", "channels": "urls: []\n"}
            system["wifi"]["environment"] = "\n".join(
                f"{name}_SSID=synthetic-{name}\n{name}_PSK=synthetic-password"
                for name in ("HOME", "TRAVEL", "IPHONE", "MIFI")) + "\n"
            backup = yaml.safe_load(Path("${../../data/secrets/backup.example.yaml}").read_text())
            backup["password"] = "synthetic-restic"
            for name, repository in backup["repositories"].items():
                repository["url"] = "s3:https://example.invalid/" + name
                repository["environment"] = "AWS_ACCESS_KEY_ID=synthetic\nAWS_SECRET_ACCESS_KEY=synthetic\n"
            for name, document in {"system": system, "backup": backup, "identity": identity}.items():
                result = subprocess.run(["sops", "encrypt", "--age", recipient, "--input-type", "yaml", "--output-type", "yaml", "/dev/stdin"],
                                        input=yaml.safe_dump(document), text=True, capture_output=True, check=True)
                (Path(os.environ["out"]) / (name + ".sops.yaml")).write_text(result.stdout)
        finally:
            subprocess.run(["gpgconf", "--homedir", str(home), "--kill", "all"], capture_output=True)
        PY
      '';
in
{
  # Exercise the host's own SOPS fields, identity and Wi-Fi bindings.
  _module.args.hostSecretsDirectory = credentials;
}
