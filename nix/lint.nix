{ pkgs }:
let
  source = pkgs.lib.fileset.toSource {
    root = ../.;
    fileset = pkgs.lib.fileset.fileFilter (
      file:
      builtins.any file.hasExt [
        "nix"
        "sh"
        "py"
        "toml"
        "json"
        "yml"
      ]
    ) ../.;
  };
in
pkgs.runCommand "source-lint"
  {
    nativeBuildInputs = with pkgs; [
      actionlint
      shellcheck
      nixfmt
      python3
    ];
  }
  ''
    cd ${source}
    actionlint .github/workflows/*.yml
    find . -type f -name '*.nix' -print0 | xargs -0 nixfmt --check
    find . -type f -name '*.sh' -print0 | xargs -0 shellcheck --shell=bash
    python3 - <<'PY'
    import ast
    import json
    from pathlib import Path
    import tomllib

    for path in Path('.').rglob('*'):
        if path.suffix == '.py':
            ast.parse(path.read_text(), filename=str(path))
        elif path.suffix == '.json':
            json.loads(path.read_text())
        elif path.suffix == '.toml':
            tomllib.loads(path.read_text())
    PY
    touch $out
  ''
