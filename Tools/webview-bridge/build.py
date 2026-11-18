#!/usr/bin/env python3
"""Builds Cell's web view bridge (bridge.c) and embeds it in CellCore.

    python3 -I Tools/webview-bridge/build.py      (needs only Xcode's clang)
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "Tools", "pe"))
import pebuild  # noqa: E402

if __name__ == "__main__":
    pebuild.build(os.path.join(HERE, "bridge.c"), os.path.join(HERE, "cell-webview-bridge.exe"),
                  os.path.join(ROOT, "Sources", "CellCore", "Launch", "WebViewBridgeBinary.swift"),
                  "WebViewBridge", "Tools/webview-bridge/build.py", subsystem=2)
