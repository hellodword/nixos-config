"""Wait for visible controls before sending keyboard input to a desktop VM."""

import os
from pathlib import Path
import re
import subprocess
import tempfile
import time


def visible(machine, pattern, timeout=60):
    # Bound image processing so a visibility check cannot consume the
    # desktop's entire idle interval. Idle locking is exercised separately.
    with machine.nested("waiting for visible text: " + pattern), tempfile.TemporaryDirectory() as directory:
        deadline = time.monotonic() + timeout
        frame = Path(directory) / "frame.png"
        raw = Path(directory) / "frame.ppm"
        prepared = Path(directory) / "text.ppm"
        try:
            while True:
                machine.send_key("ctrl")
                machine.screenshot(str(frame))
                # The driver's ImageMagick build handles PNM; netpbm
                # provides the PNG decoder used for retained screenshots.
                with raw.open("wb") as stream:
                    subprocess.run(["pngtopnm", str(frame)], stdout=stream, stderr=subprocess.PIPE, check=True, timeout=15)
                observed = []
                for contrast in ([], ["-threshold", "50%"]):
                    if time.monotonic() >= deadline:
                        break
                    machine.send_key("ctrl")
                    subprocess.run(
                        ["magick", str(raw), "-resize", "300%", "-colorspace", "Gray", *contrast, str(prepared)],
                        check=True, capture_output=True, timeout=15,
                    )
                    try:
                        result = subprocess.run(
                            ["tesseract", str(prepared), "stdout", "--oem", "1", "--psm", "11"],
                            check=True, capture_output=True, text=True,
                            timeout=min(15, max(0.1, deadline - time.monotonic())),
                            env={**os.environ, "OMP_THREAD_LIMIT": "1"},
                        ).stdout
                    except subprocess.TimeoutExpired:
                        observed.append("OCR timed out for " + ("threshold" if contrast else "grayscale"))
                        continue
                    observed.append(result)
                    if re.search(pattern, result):
                        return
                assert time.monotonic() < deadline, (pattern, observed)
                time.sleep(1)
        except Exception as error:
            if isinstance(error, subprocess.SubprocessError):
                print("Image processing failed:", getattr(error, "stderr", None))
            raise


def login(machine):
    """Authenticate through SDDM so the real PAM wallet lifecycle runs."""
    from datetime import timedelta
    machine.wait_for_unit("display-manager.service")
    machine.wait_for_unit("home-manager-desktop.service")
    # The selected account stays legible across greeter sizes; the password
    # placeholder is small and low contrast in Breeze.
    visible(machine, r"(?i)\bdesktop\b", timeout=90)
    delay = timedelta(milliseconds=150)
    machine.send_key("ctrl-u", delay=delay)
    machine.send_chars("synthetic-fixture-only", delay=delay)
    machine.send_key("ret", delay=delay)
