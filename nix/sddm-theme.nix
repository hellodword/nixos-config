{ pkgs }:
pkgs.runCommand "site-breeze-sddm-theme"
  {
    nativeBuildInputs = [ pkgs.python3 ];
    inherit (pkgs.kdePackages.plasma-desktop) meta;
  }
  ''
    mkdir -p "$out/share/sddm/themes"
    cp -rL ${pkgs.kdePackages.plasma-desktop}/share/sddm/themes/breeze "$out/share/sddm/themes/site-breeze"
    chmod -R u+w "$out/share/sddm/themes/site-breeze"
    python3 - "$out/share/sddm/themes/site-breeze/Main.qml" <<'PY'
    import re
    import sys
    from pathlib import Path

    main = Path(sys.argv[1])
    source = main.read_text()
    source, removed = re.subn(
        r'(?m)^ +ActionButton \{[^{}]*onClicked: sddm\.(?:hibernate|suspend)\(\)[^{}]*\},\n',
        "", source,
    )
    keyboard = 'id: virtualKeyboardButton\n'
    if removed != 3 or source.count(keyboard) != 1:
        raise SystemExit('Breeze login controls changed; review the site theme adaptation')
    main.write_text(source.replace(keyboard, keyboard + '                visible: false\n                enabled: false\n'))
    PY
  ''
