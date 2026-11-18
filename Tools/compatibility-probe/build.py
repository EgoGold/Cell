#!/usr/bin/env python3
"""Build the compatibility probe with Xcode clang and Cell's PE linker."""
from pathlib import Path
import sys
import tempfile
root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(root / "Tools/pe"))
import pebuild
with tempfile.TemporaryDirectory() as scratch:
    obj = pebuild.compile_object(str(Path(__file__).with_name("probe.c")), str(Path(scratch) / "probe.obj"))
    output = Path(__file__).with_name("compatibility-probe.exe")
    output.write_bytes(pebuild.link(obj))
    print(output)
