#!/usr/bin/env python3

import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
FORBIDDEN_TEXT = (
    "YTK" + "Plus",
    "YTK" + "illerPlus",
    "YTK" + "Core",
)
FORBIDDEN_PREFERENCE_PREFIXES = (
    "ACE" + "Enable",
    "ACE" + "Hide",
    "AudioNotification" + "OnSkip",
    "YTzoom" + "DownloadsTab",
    "YTzoom" + "TabNames",
    "YTKSaved" + "PlaybackRate",
    "kYTzoom" + "Progress",
    "YTzoomSponsor" + "Behavior",
    "YTzoomSponsor" + "Color",
)
STRING_LITERAL = re.compile(r'@?"([^"\n]*)"')
SKIP = {".git", ".build", "dist", "packages", ".theos"}


def main() -> int:
    failures: list[str] = []
    for path in ROOT.rglob("*"):
        if any(part in SKIP for part in path.parts):
            continue
        try:
            if not path.is_file():
                continue
            value = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        for token in FORBIDDEN_TEXT:
            if token.lower() in value.lower():
                failures.append(f"{path.relative_to(ROOT)}: contains prohibited reference")
                break
        else:
            literals = (match.group(1) for match in STRING_LITERAL.finditer(value))
            if any(literal.startswith(FORBIDDEN_PREFERENCE_PREFIXES)
                   for literal in literals):
                failures.append(
                    f"{path.relative_to(ROOT)}: contains legacy preference key"
                )
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print("provenance audit passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
