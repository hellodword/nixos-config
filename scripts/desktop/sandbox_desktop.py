"""Keep desktop resources and route each selected launch action through its wrapper."""

from pathlib import Path
import re
import sys

output, original = map(Path, sys.argv[1:3])
binaries = set(sys.argv[3:])
for desktop in (output / "share/applications").glob("*.desktop"):
    text = desktop.read_text()

    def replace(match):
        key, executable = match.groups()
        command = executable.strip('"')
        binary = Path(command).name
        if binary in binaries and command in (binary, str(original / "bin" / binary)):
            return f"{key}={output}/bin/{binary}"
        return match.group(0)

    updated = re.sub(r'^(Exec|TryExec)=("[^"]+"|[^\s]+)', replace, text, flags=re.MULTILINE)
    if updated != text:
        desktop.unlink()
        desktop.write_text(updated)
