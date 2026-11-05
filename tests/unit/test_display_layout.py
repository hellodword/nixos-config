"""Exercise the display callback's CLI and its external command boundary."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


from tests.support import ROOT

SCRIPT = ROOT / "scripts/desktop/layout.py"
QUERY = """Screen 0: minimum 8 x 8, current 5120 x 2160, maximum 32767 x 32767
DP-2 connected 5120x2160+0+0 (normal left inverted right x axis y axis)
   5120x2160 60.00*
   1280x800 60.00+
eDP-1 connected (normal left inverted right x axis y axis)
   1920x1080 60.00+
HDMI-1 disconnected (normal left inverted right x axis y axis)
"""
FAKE = """import json, os, sys
from pathlib import Path
fixture = Path(os.environ['DISPLAY_FIXTURE'])
state = json.loads((fixture / 'state.json').read_text())
call = [Path(sys.argv[0]).name, *sys.argv[1:]]
with (fixture / 'calls.jsonl').open('a') as stream:
    stream.write(json.dumps(call) + '\\n')
if call == state.get('fail'):
    print('synthetic command failure', file=sys.stderr)
    sys.exit(9)
responses = {
    ('autorandr', '--detected'): state.get('detected', ''),
    ('autorandr', '--fingerprint'): state['fingerprint'],
    ('xrandr', '--query'): state['query'],
}
print(responses.get(tuple(call), ''), end='')
"""


class DisplayLayout(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for name in ("autorandr", "xrandr"):
            command = self.root / name
            command.write_text(f"#!{sys.executable}\n" + FAKE)
            command.chmod(0o755)

    def invoke(self, **state):
        fixture = {
            "fingerprint": "DP-2 synthetic-edid-external\neDP-1 synthetic-edid-internal\n",
            "query": QUERY,
            **state,
        }
        (self.root / "calls.jsonl").write_text("")
        (self.root / "state.json").write_text(json.dumps(fixture))
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--autorandr", str(self.root / "autorandr"),
             "--xrandr", str(self.root / "xrandr")],
            env={**os.environ, "DISPLAY_FIXTURE": str(self.root)},
            capture_output=True,
            text=True,
        )
        calls = [json.loads(line) for line in (self.root / "calls.jsonl").read_text().splitlines()]
        return result, calls

    def layout(self, calls):
        command = calls[-1]
        self.assertEqual(command[0], "xrandr")
        outputs = {}
        for chunk in " ".join(command[1:]).split("--output ")[1:]:
            name, *arguments = chunk.split()
            options = {}
            while arguments:
                key = arguments.pop(0)
                options[key] = arguments.pop(0) if arguments and not arguments[0].startswith("--") else True
            outputs[name] = options
        return outputs

    def test_docking_and_lid_changes_arrange_eligible_outputs(self):
        result, calls = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        layout = self.layout(calls)
        self.assertTrue(layout["HDMI-1"]["--off"])
        self.assertTrue(layout["eDP-1"]["--primary"])
        self.assertEqual(layout["eDP-1"]["--pos"], "0x0")
        self.assertEqual(layout["DP-2"]["--right-of"], "eDP-1")
        for output in ("eDP-1", "DP-2"):
            self.assertTrue(layout[output]["--preferred"])
            self.assertEqual(layout[output]["--transform"], "none")
        query = QUERY.replace("DP-2 connected 5120x2160+0+0", "DP-2 connected 5120x2160+0+0 panning 6000x2160+0+0")
        result, calls = self.invoke(query=query, fingerprint="DP-2 synthetic-edid-external\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        layout = self.layout(calls)
        self.assertTrue(layout["eDP-1"]["--off"])
        self.assertEqual(layout["DP-2"]["--panning"], "0x0")
        self.assertEqual(layout["DP-2"]["--pos"], "0x0")

    def test_saved_profile_owns_layout_and_reports_restore_failure(self):
        for failure in (None, ["autorandr", "--change"]):
            with self.subTest(failure=failure):
                result, calls = self.invoke(detected="office\n", fail=failure)
                self.assertEqual(result.returncode, 1 if failure else 0, result.stderr)
                self.assertIn(["autorandr", "--change"], calls)
                self.assertFalse(any("--output" in call for call in calls))

    def test_incomplete_discovery_preserves_current_layout(self):
        cases = [
            ({"fingerprint": ""}, 0),
            ({"query": QUERY.replace("DP-2 connected", "DP-2 disconnected")}, 1),
            ({"fingerprint": "unexpected text with extra fields\n"}, 1),
            ({"fail": ["autorandr", "--detected"]}, 1),
        ]
        for fixture, expected in cases:
            with self.subTest(fixture=fixture):
                result, calls = self.invoke(**fixture)
                self.assertEqual(result.returncode, expected, result.stderr)
                mutations = [call for call in calls if "--output" in call or "--change" in call]
                self.assertEqual(mutations, [])


if __name__ == "__main__":
    unittest.main()
