"""Present local Tailscale state without exposing peer names or addresses."""
import json
import subprocess
import sys


def status():
    try:
        result = subprocess.run(
            ["tailscale", "status", "--json", "--peers=false"],
            capture_output=True, timeout=3, check=True,
        )
        data = json.loads(result.stdout)
        state = data.get("BackendState", "Unknown")
        online = state == "Running" and data.get("Self", {}).get("Online", False)
        return ("TS online", "online") if online else ("TS " + state, "offline")
    except (OSError, ValueError, subprocess.SubprocessError):
        return "TS unavailable", "offline"


if __name__ == "__main__":
    text, state = status()
    if sys.argv[1:] == ["--waybar"]:
        print(json.dumps({"text": text, "class": state, "tooltip": text}))
    else:
        print(text)
