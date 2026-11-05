#!/usr/bin/env python3
"""Initialize a fixed native Apprise configuration inside the application sandbox."""
import os
from pathlib import Path
import sys

import yaml


def main():
    os.umask(0o077)
    os.chdir(sys.argv[2])
    # This import and all plugin loading happen inside runsc, as an unprivileged user.
    import django
    django.setup()
    from api.auth import Authentication
    from api.utils import ConfigCache

    extra = yaml.safe_load(Path("/run/credentials/channels.yaml").read_text()) or {}
    if set(extra) - {"urls"} or not isinstance(extra.get("urls", []), list):
        raise ValueError("additional channels must be native Apprise YAML containing a urls list")
    config = {
        "template": [{"group": "bark"}, {"sound": ""}],
        "urls": [{
            "bark://bark:8080/local?group=${GROUP}&sound=${SOUND}&image=no&timeout=15":
                [{"tag": "bark"}],
        }, *extra.get("urls", [])],
    }
    # Channel addresses and credentials are literal configuration, never caller templates.
    if "${" in yaml.safe_dump(extra):
        raise ValueError("channel credentials and addresses must be literal")
    if not ConfigCache.put("local", yaml.safe_dump(config), "yaml"):
        raise RuntimeError("could not initialize notification configuration")
    if not ConfigCache.set_access("local", Authentication.ACCESS_PUBLIC):
        raise RuntimeError("could not initialize notification send access")
    os.execv(sys.argv[1], [sys.argv[1], "--config", "/dev/null", "--chdir", sys.argv[2], "--bind", "0.0.0.0:8000",
                          "--workers", "1", "--worker-class", "gevent", "--worker-connections", "16",
                          "--timeout", "40", "--graceful-timeout", "5", "--log-level", "warning",
                          "core.wsgi:application"])


if __name__ == "__main__":
    main()
