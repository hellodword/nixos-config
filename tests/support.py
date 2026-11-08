"""Locate the source tree and load the same scripts used by NixOS services."""
import importlib.util
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]


def load_source(relative):
    path = ROOT / relative
    directory = str(path.parent)
    if directory not in sys.path:
        sys.path.insert(0, directory)
    name = "tested_" + relative.replace("/", "_").removesuffix(".py")
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_script(relative):
    return load_source("scripts/" + relative)
