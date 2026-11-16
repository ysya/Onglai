#!/usr/bin/env python3
"""Prepare launchd plists inside the current build product before signing."""

import os
import plistlib
from pathlib import Path


def main():
    source_root = Path(os.environ["SRCROOT"])
    contents = Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["CONTENTS_FOLDER_PATH"]
    identifier = os.environ["PRODUCT_BUNDLE_IDENTIFIER"]
    for name, directory in (("Helper", "LaunchDaemons"), ("Sentinel", "LaunchAgents")):
        original_name = f"me.ysya.Onglai.{name}.plist"
        template = source_root / f"Pearcleaner{name}" / original_name
        data = plistlib.loads(template.read_bytes())
        label = f"{identifier}.{name}"
        data["Label"] = label
        data["AssociatedBundleIdentifiers"] = [identifier]
        if "MachServices" in data:
            data["MachServices"] = {label: True}

        destination = contents / "Library" / directory
        destination.mkdir(parents=True, exist_ok=True)
        output = destination / f"{label}.plist"
        output.write_bytes(plistlib.dumps(data))


if __name__ == "__main__":
    main()
