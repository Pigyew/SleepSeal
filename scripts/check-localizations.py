#!/usr/bin/env python3
"""Check key parity and NSString printf argument types without launching the UI."""
from collections import Counter
from pathlib import Path
import re
import subprocess
import json
import sys

ROOT = Path(__file__).resolve().parents[1]
FORMAT = re.compile(r"%(?:(\d+)\$)?[-+#0 ']*(?:(\*(?:(\d+)\$)?)|\d+)?(?:\.(?:(\*(?:(\d+)\$)?)|\d+))?(hh|ll|h|l|q|z|t|j|L)?([@diuoxXfFeEgGaAcCsSpn%])")


def arguments(value):
    next_argument = 1
    positional, sequential = False, False
    result = Counter()

    def add(position, kind):
        nonlocal next_argument, positional, sequential
        if position:
            positional = True
            index = int(position)
            if index < 1:
                raise ValueError("printf positions start at 1")
        else:
            sequential = True
            index = next_argument
            next_argument += 1
        result[index, kind] += 1

    for match in FORMAT.finditer(value):
        position, width, width_position, precision, precision_position, length, specifier = match.groups()
        if specifier == "%":
            continue
        if width:
            add(width_position, "int")
        if precision:
            add(precision_position, "int")
        if specifier in "diuoxX":
            kind = ("int" if specifier in "di" else "unsigned") + ("64" if length in {"l", "ll", "q", "z", "t", "j"} else "")
        elif specifier in "fFeEgGaA":
            kind = "long-double" if length == "L" else "double"
        else:
            kind = {"@": "object", "c": "int", "C": "int", "s": "utf8-pointer", "S": "utf16-pointer", "p": "pointer", "n": "write-count-pointer"}[specifier]
            if specifier == "n":
                raise ValueError("%n must not appear in localized text")
        add(position, kind)
    if positional and sequential:
        raise ValueError("mixed positional and sequential printf arguments")
    return result


def read_strings(path):
    # Apple's parser handles escapes and UTF-16 .strings correctly.
    result = subprocess.check_output(["/usr/bin/plutil", "-convert", "json", "-o", "-", str(path)])
    return json.loads(result)


def check(root=ROOT):
    checked = 0
    for name in ("Localizable.strings", "InfoPlist.strings"):
        english = read_strings(root / "Resources/en.lproj" / name)
        chinese = read_strings(root / "Resources/zh-Hans.lproj" / name)
        if english.keys() != chinese.keys():
            raise ValueError(f"{name}: different keys: {sorted(english.keys() ^ chinese.keys())}")
        for key, value in english.items():
            if not value or not chinese[key]:
                raise ValueError(f"{name}: empty translation: {key}")
            if arguments(value) != arguments(chinese[key]):
                raise ValueError(f"{name}: incompatible printf arguments: {key}")
            checked += 1
    return checked


if __name__ == "__main__":
    try:
        print(f"PASS: {check()} bilingual keys and NSString format arguments; no UI or hardware used")
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Localization validation failed: {error}", file=sys.stderr)
        sys.exit(1)
