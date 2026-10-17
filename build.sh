#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/cache build/SleepSeal.app/Contents/MacOS
/usr/bin/xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$PWD/build/cache" \
  Sources/StateMachine.swift Sources/MacSystem.swift Sources/Main.swift \
  -framework AppKit -framework CoreWLAN -framework IOBluetooth -framework CoreBluetooth -framework IOKit \
  -o build/SleepSeal.app/Contents/MacOS/SleepSeal
/bin/cp Resources/Info.plist build/SleepSeal.app/Contents/Info.plist
/usr/bin/codesign --force --sign - build/SleepSeal.app
echo '已生成 build/SleepSeal.app（本机架构，本地临时签名）。'
