#!/usr/bin/env python3
"""Validate native WM configuration and simplified Chinese font selection."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile



def run(args, timeout=15, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=timeout, **kwargs).stdout


def check_fonts(output, work):
    report = {"matching": [], "layout": []}
    env = os.environ | {"LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "XDG_CACHE_HOME": str(work / "font-cache")}
    for language in ("en", "zh-cn", "und"):
        for family in ("sans-serif", "serif", "monospace", "Noto Sans", "Noto Serif"):
            for char in "中骨直令返羽曜":
                matched = run(["fc-match", "--format=%{family}", f"{family}:lang={language}:charset={ord(char):x}"], env=env)
                assert " SC" in matched, (family, language, char, matched)
                report["matching"].append({"language": language, "request": family, "character": char, "font": matched})
    sample = "ABCD|ABCD|\n中文|中文|\n0O 1lI (){}[] => != 简体中文 骨直令返羽曜\n ABCD  中文\n😀 👩🏽‍💻 🇨🇳"
    for size in (16, 20, 24):
        for style in ("Regular", "Bold", "Italic"):
            layout = work / "font-layout.json"
            run(["pango-view", "--no-display", "--pixels", f"--font=monospace {style} {size}",
                 "--language=en", "--text=" + sample, "--serialize-to=" + str(layout)], env=env, timeout=60)
            lines = json.loads(layout.read_text())["output"]["lines"]
            widths = [sum(g["width"] for run in line["runs"] for g in run["glyphs"]) / 1024 for line in lines[:2]]
            assert widths[0] == widths[1], (size, style, widths)
            for line in lines:
                for shaped in line["runs"]:
                    encoded = shaped["text"].encode("utf-8")
                    for glyph in shaped["glyphs"]:
                        if glyph["glyph"] & 0x10000000:
                            char = encoded[glyph["log-cluster"]:].decode("utf-8")[0]
                            # Symbol-only fonts have no space glyph; Pango still advances it.
                            assert char.isspace(), (char, shaped["font"])
            report["layout"].append({"size": size, "style": style, "ascii_width": widths[0], "han_width": widths[1]})
    run(["pango-view", "--no-display", "--pixels", "--font=monospace 20", "--language=en",
         "--text=" + sample, "--output=" + str(output / "font-sample.png")], env=env, timeout=60)
    (output / "fonts.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--settings", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    settings = json.loads(args.settings.read_text())
    args.output.mkdir(parents=True, exist_ok=True)
    # UNIX sockets have a 108-byte path limit; a Nix build TMPDIR can be long.
    with tempfile.TemporaryDirectory(prefix="desktop-", dir="/tmp") as temporary:
        work = Path(temporary)
        check_fonts(args.output, work)
        env = os.environ | {"XDG_RUNTIME_DIR": str(work)}
        for session, command in (("sway", ["sway", "--validate", "-d"]), ("i3", ["i3", "-C"])):
            result = subprocess.run([*command, "-c", settings[session]], env=env, capture_output=True, text=True, timeout=30)
            (args.output / f"{session}-validation.log").write_text(result.stdout + result.stderr)
            if result.returncode:
                print(result.stdout + result.stderr, file=sys.stderr)
                result.check_returncode()

if __name__ == "__main__":
    main()
