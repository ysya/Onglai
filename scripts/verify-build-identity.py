#!/usr/bin/env python3
"""Check built app identities before launching an XCTest host or packaging."""

import argparse
import plistlib
from pathlib import Path


def read_plist(path):
    return plistlib.loads(path.read_bytes())


def verify(app, configuration):
    debug = configuration == "Debug"
    identifier = "me.ysya.Onglai.Debug" if debug else "me.ysya.Onglai"
    scheme = "onglai-debug" if debug else "onglai"
    group_suffix = ".group.onglai.debug" if debug else ".group.onglai"
    contents = app / "Contents"
    info = read_plist(contents / "Info.plist")
    assert info["CFBundleIdentifier"] == identifier, "Unexpected main app identifier"
    groups = info["OnglaiAppGroupIdentifier"]
    assert groups.endswith(group_suffix) and "$(" not in groups, "Unexpected app group"
    urls = info["CFBundleURLTypes"]
    assert len(urls) == 1 and urls[0]["CFBundleURLSchemes"] == [scheme], "Unexpected URL scheme"
    assert urls[0]["CFBundleURLName"] == identifier, "Unexpected URL identity"

    finder = read_plist(contents / "PlugIns/FinderOpen.appex/Contents/Info.plist")
    assert finder["CFBundleIdentifier"] == identifier + ".FinderOpen", "Unexpected Finder identifier"
    assert finder["OnglaiAppGroupIdentifier"] == groups, "App and Finder groups differ"

    for name, directory in (("Helper", "LaunchDaemons"), ("Sentinel", "LaunchAgents")):
        label = identifier + "." + name
        destination = contents / "Library" / directory
        data = read_plist(destination / f"{label}.plist")
        assert data["Label"] == label, f"Unexpected {name} label"
        assert data["AssociatedBundleIdentifiers"] == [identifier], f"Unexpected {name} owner"
        assert (contents.parent / data["BundleProgram"]).is_file(), f"Missing {name} executable"
        if name == "Helper":
            assert data["MachServices"] == {label: True}, "Unexpected helper Mach service"
        if debug:
            assert not (destination / f"me.ysya.Onglai.{name}.plist").exists(), "Production service in Debug"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--configuration", required=True, choices=("Debug", "Release"))
    args = parser.parse_args()
    verify(args.app, args.configuration)
    print(f"{args.configuration} app identity verified")


if __name__ == "__main__":
    main()
