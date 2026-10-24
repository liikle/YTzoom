#!/usr/bin/env python3

import pathlib
import plistlib
import sys

DISPLAY_NAME = "YTzoom"


def enable_file_access(root: dict) -> None:
    root["UIFileSharingEnabled"] = True
    root["LSSupportsOpeningDocumentsInPlace"] = True
    modes = root.get("UIBackgroundModes")
    if not isinstance(modes, list):
        modes = []
    if "audio" not in modes:
        modes.append("audio")
    root["UIBackgroundModes"] = modes


def set_display_name(root: dict) -> None:
    root["CFBundleDisplayName"] = DISPLAY_NAME


def main() -> int:
    if len(sys.argv) != 2:
        return 2
    path = pathlib.Path(sys.argv[1])
    with path.open("rb") as handle:
        root = plistlib.load(handle)
    enable_file_access(root)
    set_display_name(root)
    with path.open("wb") as handle:
        plistlib.dump(root, handle, fmt=plistlib.FMT_BINARY, sort_keys=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
