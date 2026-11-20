{ pkgs }:
let
  source = pkgs.lib.fileset.toSource {
    root = ../.;
    fileset = pkgs.lib.fileset.difference (pkgs.lib.fileset.fileFilter (
      file:
      builtins.any file.hasExt [
        "nix"
        "sh"
        "py"
        "toml"
        "json"
        "yml"
        "yaml"
        "js"
        "mjs"
      ]
    ) ../.) (pkgs.lib.fileset.maybeMissing ../.agents);
  };
in
pkgs.runCommand "source-lint"
  {
    nativeBuildInputs = with pkgs; [
      actionlint
      shellcheck
      nixfmt
      ruff
      nodejs
      (python3.withPackages (p: [ p.pyyaml ]))
    ];
  }
  ''
    cd ${source}
    actionlint .github/workflows/*.yml
    find . -type f -name '*.nix' -print0 | xargs -0 nixfmt --check
    find . -type f -name '*.sh' -print0 | xargs -0 shellcheck --shell=bash
    ruff check --no-cache --select E4,E7,E9,F .
    find . -type f \( -name '*.js' -o -name '*.mjs' \) -print0 | xargs -0 -r -n1 node --check
    python3 - <<'PY'
    import ast
    import json
    from pathlib import Path
    import tomllib
    import yaml

    for path in Path('.').rglob('*'):
        if path.suffix == '.py':
            ast.parse(path.read_text(), filename=str(path))
        elif path.suffix == '.json':
            json.loads(path.read_text())
        elif path.suffix == '.toml':
            tomllib.loads(path.read_text())
        elif path.suffix in {'.yaml', '.yml'}:
            list(yaml.safe_load_all(path.read_text()))
    PY
    touch $out
  ''
