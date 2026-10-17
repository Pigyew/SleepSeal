#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
. ./VERSION
[ "$(uname -m)" = arm64 ] || { echo 'SleepSeal Beta builds require Apple silicon.' >&2; exit 1; }
# Reusing the compiler cache is safe; reusing the bundle can ship deleted resources.
/bin/rm -rf build/SleepSeal.app
/bin/rm -f build/PowerControl build/build-manifest.json
mkdir -p build/cache build/SleepSeal.app/Contents/{MacOS,Resources}
python3 scripts/release-metadata.py snapshot-source
python3 scripts/release-metadata.py snapshot-source
/bin/bash make-icon.sh
/usr/bin/xcrun swiftc -swift-version 5 -O -parse-as-library -target "arm64-apple-macosx${SLEEPSEAL_MIN_MACOS}" \
  -module-cache-path "$PWD/build/cache" Sources/*.swift UI/*.swift \
  -framework AppKit -framework SwiftUI -framework CoreWLAN -framework IOBluetooth \
  -framework CoreBluetooth -framework IOKit -framework Security \
  -o build/SleepSeal.app/Contents/MacOS/SleepSeal
python3 scripts/release-metadata.py info build/SleepSeal.app/Contents/Info.plist
/bin/cp build/AppIcon.icns build/SleepSeal.app/Contents/Resources/AppIcon.icns
for resource in Resources/*.lproj; do /bin/cp -R "$resource" build/SleepSeal.app/Contents/Resources/; done
/usr/bin/codesign --force --sign - build/SleepSeal.app
/usr/bin/xcrun swiftc -swift-version 5 -O -parse-as-library -target "arm64-apple-macosx${SLEEPSEAL_MIN_MACOS}" \
  -module-cache-path "$PWD/build/cache" Helper/PowerControl.swift -o build/PowerControl
/usr/bin/codesign --force --sign - build/PowerControl
/usr/bin/codesign --verify --strict build/SleepSeal.app
/usr/bin/codesign --verify --strict build/PowerControl
python3 scripts/release-metadata.py record-build
python3 scripts/release-metadata.py verify-build
printf 'Built SleepSeal %s %s (ad-hoc signed; not notarized).\n' "$SLEEPSEAL_VERSION" "$SLEEPSEAL_CHANNEL"
