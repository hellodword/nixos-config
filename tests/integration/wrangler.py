"""Bundle the actual Workers while exercising Wrangler's host access boundary."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    with tempfile.TemporaryDirectory(prefix="wrangler-test-") as temporary:
        root = Path(temporary)
        subprocess.run(["git", "init", "--quiet", str(root)], check=True)
        home = root / "home"
        home.mkdir()
        private = home / "private.txt"
        private.write_text("host-only fixture")
        with (ROOT / "data/secrets/vps.example.yaml").open() as declaration:
            subprocess.run([sys.executable, str(ROOT / "scripts/vps/prepare.py")],
                           stdin=declaration, cwd=root, check=True)
        prepared = root / "tmp/vps"
        hidden = [str(private), str(prepared / "metadata.json"), str(Path(__file__))]
        probe = """
const fs = require('node:fs');
const assert = require('node:assert/strict');
const path = require('node:path');
for (const file of HIDDEN) {
  assert.throws(() => fs.readFileSync(file), {code: 'ENOENT'});
}
assert.equal(process.env.SSH_AUTH_SOCK, undefined);
assert.ok(fs.readFileSync('index.js', 'utf8').includes('export default'));
assert.throws(() => fs.writeFileSync('index.js', 'changed'), {code: 'EROFS'});
const state = path.join(process.env.XDG_CONFIG_HOME, '.wrangler', 'sandbox-probe');
const count = fs.existsSync(state) ? Number(fs.readFileSync(state, 'utf8')) : 0;
fs.writeFileSync(state, String(count + 1));
""".replace("HIDDEN", json.dumps(hidden))
        with socket.socket(socket.AF_UNIX) as agent:
            agent_path = str(home / "agent.sock")
            agent.bind(agent_path)
            for name in ("certificates", "subscriptions"):
                worker = prepared / "workers" / name
                (worker / "sandbox-probe.cjs").write_text(probe)
                config = json.loads((worker / "wrangler.json").read_text())
                config["build"] = {"command": "node sandbox-probe.cjs"}
                (worker / "wrangler.json").write_text(json.dumps(config))
                subprocess.run(["wrangler", "deploy", "--dry-run", "--outdir", ".wrangler/build"],
                               cwd=worker, check=True, timeout=45,
                               env=os.environ | {"HOME": str(home), "CI": "true", "SSH_AUTH_SOCK": agent_path})
        state = root / ".wrangler"
        assert (state / "sandbox-probe").read_text() == "2"
        assert state.stat().st_mode & 0o777 == 0o700
        assert private.read_text() == "host-only fixture"


if __name__ == "__main__":
    main()
