#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/cache build/SleepSeal.app/Contents/{MacOS,Resources}
/usr/bin/xcrun swiftc -swift-version 5 -O -parse-as-library -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$PWD/build/cache" Sources/*.swift UI/*.swift \
  -framework AppKit -framework SwiftUI -framework CoreWLAN -framework IOBluetooth \
  -framework CoreBluetooth -framework IOKit -framework Security \
  -o build/SleepSeal.app/Contents/MacOS/SleepSeal
/bin/cp Resources/Info.plist build/SleepSeal.app/Contents/Info.plist
for resource in Resources/*.lproj; do /bin/cp -R "$resource" build/SleepSeal.app/Contents/Resources/; done
/usr/bin/codesign --force --sign - build/SleepSeal.app
/usr/bin/xcrun swiftc -swift-version 5 -O -parse-as-library -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$PWD/build/cache" Helper/PowerControl.swift -o build/PowerControl
/usr/bin/codesign --force --sign - build/PowerControl
/usr/bin/codesign --verify --strict build/SleepSeal.app
/usr/bin/codesign --verify --strict build/PowerControl
printf '%s\n' 'Built SleepSeal 0.2.1 Beta (ad-hoc signed; not notarized).'
