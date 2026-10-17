#!/usr/bin/env python3
"""Build/package metadata and integrity gates. Never installs or runs the app."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def run(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def version(root=None):
    root = root or ROOT
    fields = dict(line.split("=", 1) for line in (root / "VERSION").read_text().splitlines()
                  if line and not line.startswith("#"))
    patterns = {"SLEEPSEAL_VERSION": r"\d+\.\d+\.\d+", "SLEEPSEAL_BUILD": r"[1-9]\d*",
                "SLEEPSEAL_CHANNEL": r"Beta", "SLEEPSEAL_MIN_MACOS": r"\d+\.\d+"}
    if fields.keys() != patterns.keys() or any(not re.fullmatch(pattern, fields[key]) for key, pattern in patterns.items()):
        raise ValueError("Invalid VERSION metadata")
    return fields


def package_name(v):
    return f"SleepSeal-{v['SLEEPSEAL_VERSION']}-{v['SLEEPSEAL_CHANNEL']}-AppleSilicon.pkg"


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def source_hashes():
    names = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=ROOT).decode().split("\0")
    return {name: digest(ROOT / name) for name in sorted(set(filter(None, names)))
            if (ROOT / name).is_file()}


def output_hashes():
    paths = list((ROOT / "build/SleepSeal.app").rglob("*")) + [ROOT / "build/PowerControl"]
    if any(path.is_symlink() for path in paths):
        raise ValueError("Build outputs must not contain symlinks")
    return {str(path.relative_to(ROOT / "build")): digest(path) for path in sorted(paths) if path.is_file()}


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def verify_build():
    manifest = json.loads((ROOT / "build/build-manifest.json").read_text())
    if manifest["version"] != version() or manifest["source_sha256"] != source_hashes():
        raise ValueError("Sources or version changed after building; rebuild before packaging")
    if manifest["outputs_sha256"] != output_hashes():
        raise ValueError("Build outputs changed after building; rebuild before packaging")
    if manifest["commit"] != run("git", "rev-parse", "HEAD"):
        raise ValueError("The checkout commit changed after building")
    info = plistlib.loads((ROOT / "build/SleepSeal.app/Contents/Info.plist").read_bytes())
    v = version()
    expected = {"CFBundleIdentifier": "local.sleepseal.guard", "CFBundleShortVersionString": v["SLEEPSEAL_VERSION"],
                "CFBundleVersion": v["SLEEPSEAL_BUILD"], "LSMinimumSystemVersion": v["SLEEPSEAL_MIN_MACOS"]}
    if any(info.get(key) != value for key, value in expected.items()):
        raise ValueError("Application metadata does not match VERSION")
    for binary in ("build/SleepSeal.app/Contents/MacOS/SleepSeal", "build/PowerControl"):
        if run("/usr/bin/lipo", "-archs", binary) != "arm64":
            raise ValueError(f"Expected an arm64-only binary: {binary}")
        load_commands = run("/usr/bin/otool", "-l", binary)
        minimums = re.findall(r"\bminos\s+(\d+(?:\.\d+){1,2})", load_commands)
        minimums += re.findall(r"\bversion\s+(\d+(?:\.\d+){1,2})", load_commands) if "LC_VERSION_MIN_MACOSX" in load_commands else []
        if not minimums or any(tuple(int(x) for x in item.split("."))[:2] != tuple(map(int, v["SLEEPSEAL_MIN_MACOS"].split("."))) for item in minimums):
            raise ValueError(f"Deployment target does not match VERSION: {binary}")
        subprocess.run(["/usr/bin/codesign", "--verify", "--strict", binary if binary.endswith("PowerControl") else "build/SleepSeal.app"], cwd=ROOT, check=True)
    return manifest


def inspect_installer(directory):
    payloads = [path for path in directory.rglob("Payload") if path.is_dir()]
    if len(payloads) != 1:
        raise ValueError("Expected one installer payload")
    payload = payloads[0]
    app, helper = "Applications/SleepSeal.app", "Library/PrivilegedHelperTools/local.sleepseal.PowerControl"
    parents = {"Applications", "Library", "Library/PrivilegedHelperTools"}
    for path in payload.rglob("*"):
        name = path.relative_to(payload).as_posix()
        if path.is_symlink() or not (name in parents or name in {app, helper} or name.startswith(app + "/")):
            raise ValueError(f"Unexpected payload path: {name}")
        if path.name in {".DS_Store", "__MACOSX", "pending.json", "runtime-status.json"} or path.suffix in {".log", ".p12", ".key"}:
            raise ValueError(f"Private/unexpected payload: {name}")
    if not (payload / helper).is_file() or not (payload / app / "Contents/MacOS/SleepSeal").is_file():
        raise ValueError("Missing app/helper")
    if not (payload / app / "Contents/Resources/AppIcon.icns").read_bytes().startswith(b"icns"):
        raise ValueError("Missing app icon")
    for script in ("preinstall", "postinstall"):
        if len(list(directory.rglob(script))) != 1:
            raise ValueError(f"Missing/duplicate {script}")
    info = ET.parse(next(directory.rglob("PackageInfo"))).getroot()
    if info.get("install-location") != "/" or info.get("auth") != "root" or info.get("version") != version()["SLEEPSEAL_VERSION"]:
        raise ValueError("Installer metadata mismatch")
    if info.find("relocate") is not None and list(info.find("relocate")):
        raise ValueError("Installer must not relocate the application")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["name", "info", "distribution", "snapshot-source", "record-build", "verify-build", "record-package", "verify-package", "inspect-installer", "check-tag"])
    parser.add_argument("path", nargs="?")
    parser.add_argument("--commit")
    parser.add_argument("--require-clean", action="store_true")
    args = parser.parse_args()
    v = version()
    if args.command == "name":
        print(package_name(v))
    elif args.command == "info":
        info = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())
        info.update(CFBundleShortVersionString=v["SLEEPSEAL_VERSION"], CFBundleVersion=v["SLEEPSEAL_BUILD"], LSMinimumSystemVersion=v["SLEEPSEAL_MIN_MACOS"])
        Path(args.path).write_bytes(plistlib.dumps(info))
    elif args.command == "distribution":
        text = (ROOT / "Packaging/Distribution.xml").read_text()
        for key, value in v.items():
            text = text.replace("@" + key + "@", value)
        Path(args.path).write_text(text)
    elif args.command == "snapshot-source":
        write_json(ROOT / "build/build-source.json", source_hashes())
    elif args.command == "record-build":
        sources = source_hashes()
        if sources != json.loads((ROOT / "build/build-source.json").read_text()):
            raise ValueError("Sources changed during compilation; rebuild before packaging")
        xcode = subprocess.run(["/usr/bin/xcodebuild", "-version"], capture_output=True, text=True)
        manifest = {"schema": 1, "version": v, "commit": run("git", "rev-parse", "HEAD"),
                    "dirty": bool(run("git", "status", "--porcelain")), "source_sha256": sources,
                    "outputs_sha256": output_hashes(), "architecture": "arm64", "signing": "ad-hoc; not notarized",
                    "compiler_arguments": ["-swift-version", "5", "-O", "-parse-as-library", "-target", "arm64-apple-macosx" + v["SLEEPSEAL_MIN_MACOS"]],
                    "toolchain": {"swift": run("/usr/bin/xcrun", "swiftc", "--version"),
                                  "swiftc_sha256": digest(Path(run("/usr/bin/xcrun", "--find", "swiftc"))),
                                  "xcode": xcode.stdout.strip() if xcode.returncode == 0 else "Command Line Tools; xcodebuild unavailable",
                                  "macos_sdk": run("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version")},
                    "github_run_id": os.environ.get("GITHUB_RUN_ID"), "github_run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT")}
        write_json(ROOT / "build/build-manifest.json", manifest)
    elif args.command == "verify-build":
        verify_build()
    elif args.command == "record-package":
        manifest = verify_build()
        manifest["package"] = {"name": package_name(v), "sha256": digest(ROOT / "build" / package_name(v))}
        write_json(ROOT / "build" / (package_name(v) + ".manifest.json"), manifest)
    elif args.command == "verify-package":
        directory = Path(args.path)
        manifest = json.loads((directory / (package_name(v) + ".manifest.json")).read_text())
        if manifest["version"] != v or manifest["package"] != {"name": package_name(v), "sha256": digest(directory / package_name(v))}:
            raise ValueError("Release package/version integrity failed")
        if args.commit and manifest["commit"] != args.commit:
            raise ValueError("Release commit does not match the checked build")
        if args.require_clean and (manifest["dirty"] or manifest["source_sha256"] != source_hashes()):
            raise ValueError("Release must come from this clean, unchanged source tree")
        if os.environ.get("GITHUB_RUN_ID") and manifest["github_run_id"] != os.environ["GITHUB_RUN_ID"]:
            raise ValueError("Release must use the artifact from this workflow run")
        expected = f"{manifest['package']['sha256']}  {package_name(v)}\n"
        if (directory / (package_name(v) + ".sha256")).read_text() != expected:
            raise ValueError("Release checksum file does not match the manifest")
    elif args.command == "inspect-installer":
        inspect_installer(Path(args.path))
    elif args.command == "check-tag":
        if args.path != "v" + v["SLEEPSEAL_VERSION"]:
            raise ValueError("Release tag must match VERSION exactly")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        print(f"Release validation failed: {error}", file=sys.stderr)
        sys.exit(1)
