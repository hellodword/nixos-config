"""Present this host's Tailscale connection and addresses."""
import html
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
        text, style = ("TS online", "online") if online else ("TS " + state, "offline")
        addresses = data.get("TailscaleIPs") or data.get("Self", {}).get("TailscaleIPs", [])
        details = "Tailscale: " + state + "\n" + "\n".join(addresses)
        return text, style, details.strip()
    except (OSError, ValueError, subprocess.SubprocessError):
        return "TS unavailable", "offline", "Tailscale status unavailable"


if __name__ == "__main__":
    text, state, tooltip = status()
    if sys.argv[1:] == ["--waybar"]:
        print(json.dumps({"text": text, "class": state, "tooltip": html.escape(tooltip)}))
    else:
        print(text)
